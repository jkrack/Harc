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

    public var currentJoinedText: String {
        chunks.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
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
