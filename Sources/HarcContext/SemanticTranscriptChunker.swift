import Foundation

public struct PreparedTranscriptChunk: Sendable, Equatable {
    public var ordinal: Int
    public var startMs: Int
    public var endMs: Int
    public var text: String

    public init(ordinal: Int, startMs: Int, endMs: Int, text: String) {
        self.ordinal = ordinal
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

public enum SemanticTranscriptChunker {
    public static func split(
        transcript: String,
        targetWords: Int = 220,
        maxWords: Int = 320
    ) -> [PreparedTranscriptChunk] {
        let sentences = sentenceLikeUnits(from: transcript)
        guard !sentences.isEmpty else { return [] }

        var chunks: [PreparedTranscriptChunk] = []
        var current: [String] = []
        var currentWords = 0

        func flush() {
            let text = current.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let ordinal = chunks.count
            chunks.append(PreparedTranscriptChunk(
                ordinal: ordinal,
                startMs: 0,
                endMs: 0,
                text: text
            ))
            current.removeAll()
            currentWords = 0
        }

        for sentence in sentences {
            let count = wordCount(sentence)
            if !current.isEmpty, currentWords + count > maxWords {
                flush()
            }

            current.append(sentence)
            currentWords += count

            if currentWords >= targetWords {
                flush()
            }
        }

        flush()
        return chunks
    }

    private static func sentenceLikeUnits(from transcript: String) -> [String] {
        var units: [String] = []
        var current = ""

        for character in transcript {
            current.append(character)
            if character == "." || character == "!" || character == "?" || character == "\n" {
                let unit = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !unit.isEmpty { units.append(unit) }
                current = ""
            }
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { units.append(tail) }

        return units
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }).count
    }
}
