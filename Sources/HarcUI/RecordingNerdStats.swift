import Foundation
import HarcClient
import HarcCore
import HarcStore

/// Everything Harc computed for a recording that never had a surface:
/// pipeline throughput, speech dynamics, voiceprint facts, index state.
/// Assembled from data already on disk — building stats never triggers new
/// model work.
///
/// Pure and synchronous by design; the async I/O (sidecar decode, store
/// reads, file sizes) lives at the call site so this stays trivially
/// testable.
struct RecordingNerdStats: Equatable {

    struct SpeakerShare: Equatable, Identifiable {
        let index: Int
        let talkMs: Int
        /// Fraction of all attributed speech (not of wall clock).
        let share: Double
        var id: Int { index }
    }

    struct Voiceprint: Equatable {
        let speakerIndex: Int
        let dimensions: Int
        let segmentCount: Int
        let totalMs: Int
        let embedderKind: String?
    }

    // Audio
    var durationSeconds: Double?
    var wavBytes: Int64?

    // Transcription pipeline
    var chunkCount: Int = 0
    var totalProcessingMs: Int = 0
    /// Seconds of audio transcribed per second of compute. The ANE flex
    /// number.
    var realtimeFactor: Double?
    var sttModelID: String?
    var transcribedAt: Date?

    // Speech dynamics
    var wordCount: Int = 0
    var wordsPerMinute: Double?
    /// Fraction of the recording covered by diarized speech — the visible
    /// version of "meetings are 40–70% silence".
    var speechCoverage: Double?
    var speakerTurns: Int = 0
    var longestMonologueMs: Int = 0

    // Voices
    var speakerShares: [SpeakerShare] = []
    var voiceprints: [Voiceprint] = []

    // Intelligence
    var summaryModelID: String?
    var summaryGeneratedAt: Date?
    var summarySourceWordCount: Int?
    var semanticChunkCount: Int = 0
    var semanticEmbedderID: String?

    // MARK: - Building

    static func build(
        recording: Recording,
        transcript: SessionTranscript?,
        voiceprintRows: [RecordingStore.SpeakerEmbeddingRow] = [],
        semanticChunkCount: Int = 0,
        semanticEmbedderID: String? = nil,
        wavBytes: Int64? = nil
    ) -> RecordingNerdStats {
        var stats = RecordingNerdStats()
        stats.wavBytes = wavBytes
        stats.sttModelID = recording.sttModelID
        stats.transcribedAt = recording.transcribedAt
        stats.summaryModelID = recording.summaryModelID
        stats.summaryGeneratedAt = recording.summaryGeneratedAt
        stats.summarySourceWordCount = recording.summarySourceWordCount
        stats.semanticChunkCount = semanticChunkCount
        stats.semanticEmbedderID = semanticEmbedderID

        let durationSeconds = recording.endedAt.map { $0.timeIntervalSince(recording.startedAt) }
        stats.durationSeconds = durationSeconds

        stats.voiceprints = voiceprintRows.map {
            Voiceprint(
                speakerIndex: $0.speakerIndex,
                dimensions: $0.embedding.count / MemoryLayout<Float32>.size,
                segmentCount: $0.segmentCount,
                totalMs: $0.totalMs,
                embedderKind: $0.embedderKind
            )
        }.sorted { $0.speakerIndex < $1.speakerIndex }

        guard let transcript else { return stats }

        stats.chunkCount = transcript.chunks.count
        stats.totalProcessingMs = transcript.chunks.reduce(0) { $0 + $1.processingMs }
        stats.wordCount = transcript.joinedText
            .split(whereSeparator: { $0.isWhitespace }).count

        if let durationSeconds, durationSeconds > 0 {
            if stats.totalProcessingMs > 0 {
                stats.realtimeFactor = (durationSeconds * 1000) / Double(stats.totalProcessingMs)
            }
            if stats.wordCount > 0 {
                stats.wordsPerMinute = Double(stats.wordCount) / (durationSeconds / 60)
            }
        }

        let segments = transcript.speakers.sorted { $0.startMs < $1.startMs }
        guard !segments.isEmpty else { return stats }

        // Coverage: union of segment intervals over wall clock. Segments can
        // overlap (crosstalk), so merge before summing.
        var mergedMs = 0
        var currentStart = segments[0].startMs
        var currentEnd = segments[0].endMs
        for seg in segments.dropFirst() {
            if seg.startMs <= currentEnd {
                currentEnd = max(currentEnd, seg.endMs)
            } else {
                mergedMs += currentEnd - currentStart
                currentStart = seg.startMs
                currentEnd = seg.endMs
            }
        }
        mergedMs += currentEnd - currentStart
        if let durationSeconds, durationSeconds > 0 {
            stats.speechCoverage = min(1.0, Double(mergedMs) / (durationSeconds * 1000))
        }

        // Turns + longest monologue: runs of consecutive same-speaker
        // segments. A run's length spans first start to last end, so the
        // short pauses inside one person's answer stay part of the monologue.
        var turns = 0
        var longestMs = 0
        var runSpeaker = segments[0].speaker
        var runStart = segments[0].startMs
        var runEnd = segments[0].endMs
        for seg in segments.dropFirst() {
            if seg.speaker == runSpeaker {
                runEnd = max(runEnd, seg.endMs)
            } else {
                turns += 1
                longestMs = max(longestMs, runEnd - runStart)
                runSpeaker = seg.speaker
                runStart = seg.startMs
                runEnd = seg.endMs
            }
        }
        longestMs = max(longestMs, runEnd - runStart)
        stats.speakerTurns = turns + 1
        stats.longestMonologueMs = longestMs

        // Talk time per speaker, as a share of attributed speech.
        var talkBySpeaker: [Int: Int] = [:]
        for seg in segments {
            talkBySpeaker[seg.speaker, default: 0] += seg.endMs - seg.startMs
        }
        let totalTalk = talkBySpeaker.values.reduce(0, +)
        if totalTalk > 0 {
            stats.speakerShares = talkBySpeaker
                .map { SpeakerShare(index: $0.key, talkMs: $0.value, share: Double($0.value) / Double(totalTalk)) }
                .sorted { $0.talkMs > $1.talkMs }
        }

        return stats
    }
}
