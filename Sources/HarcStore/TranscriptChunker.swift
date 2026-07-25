import Foundation

/// Splits a transcript into overlapping windows suitable for embedding.
///
/// Retrieval works on passages, not whole meetings: an hour-long transcript
/// embedded as one vector averages away everything that made any part of it
/// worth finding. Windows overlap so a point made across a boundary is still
/// wholly present in at least one chunk.
///
/// Chunking is done on word counts rather than characters — it is the unit
/// embedding models are budgeted in, and it keeps chunks comparable regardless
/// of how verbose a speaker is.
public struct TranscriptChunker: Sendable {
    public struct Chunk: Sendable, Equatable {
        public var ordinal: Int
        public var text: String
        /// Offsets within the transcript, in milliseconds. Interpolated from
        /// the chunk's word span when the caller supplies a duration, so a hit
        /// can deep-link into the audio rather than just naming the recording.
        public var startMs: Int
        public var endMs: Int

        public init(ordinal: Int, text: String, startMs: Int, endMs: Int) {
            self.ordinal = ordinal
            self.text = text
            self.startMs = startMs
            self.endMs = endMs
        }
    }

    /// Words per chunk.
    public var windowWords: Int
    /// Words each chunk shares with the previous one.
    public var overlapWords: Int

    public init(windowWords: Int = 180, overlapWords: Int = 40) {
        precondition(windowWords > 0, "window must be positive")
        precondition(overlapWords >= 0 && overlapWords < windowWords,
                     "overlap must be smaller than the window or chunking cannot advance")
        self.windowWords = windowWords
        self.overlapWords = overlapWords
    }

    /// Split `text` into overlapping chunks.
    ///
    /// `durationMs` spreads timestamps proportionally across the transcript.
    /// It is an approximation — words are not uniformly spaced in time — but it
    /// is monotonic and good enough to seek near a hit. Pass nil to get zeroed
    /// timestamps when the duration isn't known.
    public func chunks(of text: String, durationMs: Int? = nil) -> [Chunk] {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard !words.isEmpty else { return [] }

        let stride = windowWords - overlapWords
        var result: [Chunk] = []
        var start = 0
        var ordinal = 0

        while start < words.count {
            let end = min(start + windowWords, words.count)
            let slice = words[start..<end]
            let startMs = timestamp(forWord: start, of: words.count, durationMs: durationMs)
            let endMs = timestamp(forWord: end, of: words.count, durationMs: durationMs)
            result.append(Chunk(
                ordinal: ordinal,
                text: slice.joined(separator: " "),
                startMs: startMs,
                endMs: endMs
            ))
            ordinal += 1

            // The final window is short; emitting it and stopping avoids a
            // trailing chunk that merely repeats the overlap of its predecessor.
            if end == words.count { break }
            start += stride
        }
        return result
    }

    private func timestamp(forWord index: Int, of total: Int, durationMs: Int?) -> Int {
        guard let durationMs, total > 0 else { return 0 }
        return Int((Double(index) / Double(total)) * Double(durationMs))
    }
}
