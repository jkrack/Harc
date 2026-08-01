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

    /// Ordered chunks with boundary overlaps stitched away. Computed at
    /// read time so `add` stays idempotent and retry-safe.
    private var stitchedChunks: [ChunkResult] {
        Self.stitchAdjacent(orderedChunks)
    }

    public var currentJoinedText: String {
        stitchedChunks.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Overlap stitching

    /// When the chunker extends slices past their nominal boundary, adjacent
    /// chunks both transcribe the shared seconds — the boundary word arrives
    /// whole in each instead of split ("…rn." artifacts). This removes the
    /// duplicate: find the longest common word run between a chunk's tail
    /// and its successor's head, keep the predecessor's version (it had a
    /// full chunk of left context), and drop the matched prefix from the
    /// successor. No match (silence at the boundary, wildly different
    /// recognitions) falls back to the plain hard join.
    ///
    /// Stitching operates on the chunk's plain `text` split by whitespace —
    /// NEVER by joining `Word` entries, which are SentencePiece token-level
    /// and reassemble into garbled words (the live-preview lesson).
    static func stitchAdjacent(_ ordered: [ChunkResult]) -> [ChunkResult] {
        guard ordered.count > 1 else { return ordered }
        var out: [ChunkResult] = [ordered[0]]
        for next in ordered.dropFirst() {
            let prev = out[out.count - 1]
            let overlapMs = prev.endMs - next.startMs
            guard overlapMs > 0, !prev.text.isEmpty, !next.text.isEmpty else {
                out.append(next)
                continue
            }
            guard let droppedWordCount = overlapPrefixLength(
                previousTail: prev.text, nextHead: next.text
            ) else {
                out.append(next)
                continue
            }
            let nextWords = next.text.split(separator: " ", omittingEmptySubsequences: true)
            let trimmedText = nextWords.dropFirst(droppedWordCount).joined(separator: " ")
            // The successor's word timings over the shared audio duplicate
            // the predecessor's; drop them along with the text so seek and
            // the (future) gutter don't see the boundary twice.
            let trimmedWords = next.words.filter { $0.startMs >= overlapMs }
            out.append(ChunkResult(
                startMs: next.startMs,
                endMs: next.endMs,
                text: trimmedText,
                words: trimmedWords,
                speakers: next.speakers,
                processingMs: next.processingMs
            ))
        }
        return out
    }

    /// How many leading whitespace-words of `nextHead` duplicate the end of
    /// `previousTail` — nil when no confident match exists. Compares a
    /// bounded window from each side, normalized (lowercased, punctuation
    /// stripped), and requires a run of at least two words so a lone "the"
    /// can't stitch two unrelated sentences.
    static func overlapPrefixLength(
        previousTail: String,
        nextHead: String,
        window: Int = 16
    ) -> Int? {
        func normalize(_ s: Substring) -> String {
            String(s).lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let tail = previousTail.split(separator: " ", omittingEmptySubsequences: true)
            .suffix(window).map(normalize)
        let headWords = nextHead.split(separator: " ", omittingEmptySubsequences: true)
        let head = headWords.prefix(window).map(normalize)
        guard tail.count >= 2, head.count >= 2 else { return nil }

        var best = 0
        for k in stride(from: min(head.count, tail.count), through: 2, by: -1) {
            let candidate = Array(head.prefix(k))
            for start in 0...(tail.count - k) where Array(tail[start..<start + k]) == candidate {
                best = k
                break
            }
            if best > 0 { break }
        }
        return best >= 2 ? best : nil
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
        let chunks = stitchedChunks
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
