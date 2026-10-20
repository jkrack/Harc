import Foundation
import CoreML
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
        public var overlapRanges: [SpeechOverlapRange]?
        public init(segments: [SpeakerSegment], speakers: [SpeakerEmbeddingRow]) {
            self.segments = segments
            self.speakers = speakers
            self.overlapRanges = nil
        }
    }

    private var manager: DiarizerManager?
    private var shortExtractor: EmbeddingExtractor?
    private var segmentationModel: MLModel?
    private var maskFrames = 0
    private let audioConverter = AudioConverter()

    public init() {}

    public var isLoaded: Bool { manager != nil }

    /// FluidAudio's tracker uses cosine distance. Its default permits much
    /// weaker matches than Harc's 0.65 cross-recording identity starting point.
    /// Keep this conservative floor explicit; broad human-voice calibration
    /// remains separate from the local synthetic regression fixtures.
    static func makeManager() -> DiarizerManager {
        let manager = DiarizerManager(config: .default)
        let maximumDistance: Float = 1 - 0.65
        manager.speakerManager.speakerThreshold = maximumDistance
        manager.speakerManager.embeddingThreshold = min(
            manager.speakerManager.embeddingThreshold, maximumDistance
        )
        return manager
    }

    public func loadModels() async throws {
        guard manager == nil else { return }
        let m = Self.makeManager()
        let models = try await DiarizerModels.download()
        shortExtractor = EmbeddingExtractor(embeddingModel: models.embeddingModel)
        segmentationModel = models.segmentationModel
        maskFrames = models.embeddingModel.modelDescription.inputDescriptionsByName["mask"]?.multiArrayConstraint?.shape.last?.intValue ?? 0
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

        // Each request is a complete recording. Keep speaker tracking across
        // its windows, never across independent recordings.
        m.speakerManager.reset()
        let windowSize = Int(DiarizerConfig.default.chunkDuration.rounded()) * 16_000
        var allSegments: [TimedSpeakerSegment] = []
        var speakerDatabase: [String: [Float]]?
        var overlapRanges: [SpeechOverlapRange] = []
        var shortRawSegmentation: [[Float]] = []
        guard let segmentationModel else { throw DaemonError.modelNotLoaded }
        let segmentationProcessor = SegmentationProcessor()
        for window in DiarizationWindowPlan.windows(sampleCount: samples.count, windowSize: windowSize) {
            let raw = try segmentationProcessor.getSegments(
                audioChunk: samples[window.source], segmentationModel: segmentationModel
            ).segments.first ?? []
            overlapRanges.append(contentsOf: try Self.rawOverlapRanges(
                raw, sourceStartSample: window.source.lowerBound, ownedSamples: window.owned
            ))
            if samples.count < windowSize { shortRawSegmentation = raw }
            let result = try m.performCompleteDiarization(
                samples[window.source], atTime: Double(window.source.lowerBound) / 16_000
            )
            let ownedStart = Float(window.owned.lowerBound) / 16_000
            let ownedEnd = Float(window.owned.upperBound) / 16_000
            for segment in result.segments {
                let start = max(segment.startTimeSeconds, ownedStart)
                let end = min(segment.endTimeSeconds, ownedEnd)
                guard end > start else { continue }
                allSegments.append(TimedSpeakerSegment(
                    speakerId: segment.speakerId, embedding: segment.embedding,
                    startTimeSeconds: start, endTimeSeconds: end, qualityScore: segment.qualityScore
                ))
            }
            speakerDatabase = result.speakerDatabase
        }

        // Map FluidAudio's String speakerIds to stable sequential Ints,
        // preserving insertion order. We need the mapping in two passes —
        // once for segments, once for the per-speaker embedding rollup.
        var speakerIndexByID: [String: Int] = [:]
        var segments: [SpeakerSegment] = []
        segments.reserveCapacity(allSegments.count)
        for seg in allSegments {
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
        var speakers = Self.buildSpeakerEmbeddingRows(
            segments: allSegments,
            speakerIndexByID: speakerIndexByID,
            speakerDatabase: speakerDatabase
        )

        // Manager pads the segmentation window to ten seconds before handing
        // it to the embedder. For short recordings that defeats the extractor's
        // native repeat-padding of real audio and its matching activity mask.
        // Re-extract identity only; never repeat published audio or timestamps.
        if samples.count < windowSize {
            // Tracking can omit an overlapping channel when it lacks enough clean
            // audio for an embedding. Keep raw segmentation independent of that
            // reduced timeline before selecting identity samples.
            if maskFrames > 0, let shortExtractor {
                let raw = shortRawSegmentation
                var isolatedSpeakers: [SpeakerEmbeddingRow] = []
                for speaker in speakers {
                    let mask = Self.shortRecordingMask(
                        speakerIndex: speaker.speakerIndex, segments: segments,
                        frameCount: maskFrames, windowDurationMs: Double(windowSize) / 16,
                        rawSegmentation: raw
                    )
                    let activeFrames = mask.reduce(Float(0), +)
                    guard activeFrames >= DiarizerConfig.default.minActiveFramesCount else { continue }
                    guard let vector = try shortExtractor.getEmbeddings(audio: samples, masks: [mask]).first,
                          vector.allSatisfy(\.isFinite) else { continue }
                    let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
                    guard norm.isFinite, norm > 0 else { continue }
                    let isolatedMs = Int(Double(activeFrames) * Double(windowSize) / 16 / Double(maskFrames))
                    isolatedSpeakers.append(SpeakerEmbeddingRow(
                        speakerIndex: speaker.speakerIndex, vector: vector.map { $0 / norm },
                        totalMs: min(speaker.totalMs, isolatedMs), segmentCount: speaker.segmentCount
                    ))
                }
                // Do not fall back to the earlier centroid after isolation fails.
                speakers = isolatedSpeakers
            } else {
                speakers = []
            }
        }
        let mergedOverlap = try Self.mergeOverlapRanges(overlapRanges)
        speakers = Self.retainSpeakersWithExclusiveSupport(speakers, segments: segments, overlap: mergedOverlap)
        var output = DiarizationOutput(segments: segments, speakers: speakers)
        output.overlapRanges = mergedOverlap
        return output
    }

    /// A centroid alone cannot authorize identity when the published timeline
    /// contains no isolated speech for its cluster. Keep the timeline intact so
    /// downstream completion can report missing evidence rather than silence.
    /// This gate does not relabel or shorten an embedding's duration claim.
    static func retainSpeakersWithExclusiveSupport(
        _ speakers: [SpeakerEmbeddingRow], segments: [SpeakerSegment], overlap: [SpeechOverlapRange]
    ) -> [SpeakerEmbeddingRow] {
        struct Event { let time: Int; let speaker: Int?; let delta: Int }
        var events: [Event] = []
        for segment in segments where segment.endMs > segment.startMs {
            events.append(Event(time: segment.startMs, speaker: segment.speaker, delta: 1))
            events.append(Event(time: segment.endMs, speaker: segment.speaker, delta: -1))
        }
        for range in overlap {
            events.append(Event(time: range.startMs, speaker: nil, delta: 1))
            events.append(Event(time: range.endMs, speaker: nil, delta: -1))
        }
        events.sort { $0.time < $1.time }
        var counts: [Int: Int] = [:], overlapDepth = 0, index = 0
        var supported = Set<Int>()
        while index < events.count {
            let start = events[index].time
            while index < events.count, events[index].time == start {
                let event = events[index]
                if let speaker = event.speaker {
                    let count = (counts[speaker] ?? 0) + event.delta
                    if count == 0 { counts.removeValue(forKey: speaker) } else { counts[speaker] = count }
                } else { overlapDepth += event.delta }
                index += 1
            }
            if index < events.count, events[index].time > start, overlapDepth == 0,
               counts.count == 1, let speaker = counts.keys.first {
                supported.insert(speaker)
            }
        }
        return speakers.filter { supported.contains($0.speakerIndex) }
    }

    /// Raw pyannote frame support uses the pinned model's 991-sample receptive
    /// window and 270-sample hop. Preserve that support conservatively, clip to
    /// owned real audio, and never derive it from tracked speaker IDs.
    static func rawOverlapRanges(
        _ frames: [[Float]], sourceStartSample: Int, ownedSamples: Range<Int>
    ) throws -> [SpeechOverlapRange] {
        guard !frames.isEmpty, sourceStartSample >= 0, ownedSamples.lowerBound >= sourceStartSample,
              frames.allSatisfy({ $0.count == 3 && $0.allSatisfy({ $0 == 0 || $0 == 1 }) }) else {
            throw DaemonError.audioLoadFailed("Invalid raw speaker segmentation")
        }
        var ranges: [SpeechOverlapRange] = []
        for (index, frame) in frames.enumerated() where frame.reduce(0, +) > 1 {
            let startSample = max(ownedSamples.lowerBound, sourceStartSample + index * 270)
            let endSample = min(ownedSamples.upperBound, sourceStartSample + index * 270 + 991)
            guard endSample > startSample else { continue }
            ranges.append(try SpeechOverlapRange(startMs: startSample / 16, endMs: (endSample + 15) / 16))
        }
        return try mergeOverlapRanges(ranges)
    }

    static func mergeOverlapRanges(_ ranges: [SpeechOverlapRange]) throws -> [SpeechOverlapRange] {
        var result: [SpeechOverlapRange] = []
        for range in ranges.sorted(by: { $0.startMs < $1.startMs }) {
            if let last = result.last, range.startMs <= last.endMs {
                result[result.count - 1] = try SpeechOverlapRange(
                    startMs: last.startMs, endMs: max(last.endMs, range.endMs)
                )
            } else { result.append(range) }
        }
        return result
    }

    /// Only exclusive speaker frames contribute; overlap and silence stay masked.
    static func shortRecordingMask(
        speakerIndex: Int, segments: [SpeakerSegment], frameCount: Int,
        windowDurationMs: Double, rawSegmentation: [[Float]]
    ) -> [Float] {
        guard frameCount > 0, windowDurationMs.isFinite, windowDurationMs > 0 else { return [] }
        guard !rawSegmentation.isEmpty,
              rawSegmentation.allSatisfy({ $0.count == 3 && $0.allSatisfy({ $0 == 0 || $0 == 1 }) }) else {
            return [Float](repeating: 0, count: frameCount)
        }
        return (0..<frameCount).map { frame in
            // Reject every embedding bin touched by raw overlap, even if frame
            // grids differ or the overlapping channel has no final speaker ID.
            let first = frame * rawSegmentation.count / frameCount
            let end = ((frame + 1) * rawSegmentation.count + frameCount - 1) / frameCount
            guard !rawSegmentation[first..<end].contains(where: { $0.reduce(0, +) > 1 }) else { return 0 }
            let ms = (Double(frame) + 0.5) * windowDurationMs / Double(frameCount)
            let active = Set(segments.filter {
                Double($0.startMs) <= ms && ms < Double($0.endMs)
            }.map(\.speaker))
            return active == [speakerIndex] ? 1 : 0
        }
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
