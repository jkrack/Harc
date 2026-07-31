import Foundation
import HarcCore

/// Accumulates ChunkResults and produces a finalized SessionTranscript.
/// Word timings and speaker segments are already rebased to session-global time
/// when ChunkResult is constructed (chunker-side chunks carry their startMs).
public final class TranscriptAssembler {
    private var chunks: [ChunkResult] = []

    public init() {}

    public func add(_ chunk: ChunkResult) {
        chunks.append(chunk)
    }

    /// Chunks in session-time order. Retried chunks (e.g. a chunk that
    /// waited out a first-run model download) can be added late; sorting
    /// by startMs keeps the transcript in spoken order regardless.
    private var orderedChunks: [ChunkResult] {
        chunks.sorted { $0.startMs < $1.startMs }
    }

    public var currentJoinedText: String {
        orderedChunks.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Session-time end of the newest committed chunk — the boundary past
    /// which live-preview text is genuinely new rather than a duplicate.
    public var currentEndMs: Int {
        chunks.map(\.endMs).max() ?? 0
    }

    public func finalize(
        startedAt: Date,
        endedAt: Date,
        audioPath: String
    ) -> SessionTranscript {
        let joined = currentJoinedText

        // Rebase per-chunk word/speaker timings into session-global time.
        var allWords: [Word] = []
        var allSpeakers: [SpeakerSegment] = []
        let chunks = orderedChunks
        for chunk in chunks {
            let offset = chunk.startMs
            for w in chunk.words {
                allWords.append(Word(text: w.text, startMs: w.startMs + offset, endMs: w.endMs + offset))
            }
            for s in chunk.speakers {
                allSpeakers.append(SpeakerSegment(
                    speaker: s.speaker,
                    startMs: s.startMs + offset,
                    endMs: s.endMs + offset
                ))
            }
        }

        return SessionTranscript(
            startedAt: startedAt,
            endedAt: endedAt,
            audioPath: audioPath,
            joinedText: joined,
            words: allWords,
            speakers: allSpeakers,
            chunks: chunks
        )
    }
}
