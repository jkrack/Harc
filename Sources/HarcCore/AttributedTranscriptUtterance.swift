import Foundation

/// Lossless local representation of an utterance and its optional finer word timings.
/// Speaker indices are scoped to the selected transcript generation, not Person IDs.
public struct AttributedTranscriptUtterance: Codable, Equatable, Sendable {
    public var text: String
    public let startMs: Int
    public let endMs: Int
    public var speakerAttribution: WordSpeakerAttribution?
    public var words: [Word]

    public init(text: String, startMs: Int, endMs: Int,
                speakerAttribution: WordSpeakerAttribution? = nil, words: [Word] = []) throws {
        guard startMs >= 0, endMs > startMs,
              words.allSatisfy({ $0.startMs >= startMs && $0.endMs > $0.startMs && $0.endMs <= endMs }) else {
            throw ValidationError.invalidTimeRange
        }
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.speakerAttribution = speakerAttribution
        self.words = words
    }

    /// Explicit word assignments (including unresolved) override the parent.
    /// Absence of word timings returns no words; never synthesize token timestamps.
    public var wordsWithInheritedAttribution: [Word] {
        words.map { value in
            var word = value
            if word.speakerAttribution == nil { word.speakerAttribution = speakerAttribution }
            return word
        }
    }

    public enum ValidationError: Error { case invalidTimeRange }
    private enum CodingKeys: String, CodingKey { case text, startMs, endMs, speakerAttribution, words }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(text: values.decode(String.self, forKey: .text),
            startMs: values.decode(Int.self, forKey: .startMs), endMs: values.decode(Int.self, forKey: .endMs),
            speakerAttribution: values.decodeIfPresent(WordSpeakerAttribution.self, forKey: .speakerAttribution),
            words: values.decodeIfPresent([Word].self, forKey: .words) ?? [])
    }
}

public struct AttributedTranscriptRun: Equatable, Sendable {
    public let text: String
    public let speakerIndex: Int?
    public let overlaps: Bool
}

public extension AttributedTranscriptUtterance {
    func displayRuns(speakers: [SpeakerSegment], overlapRanges: [SpeechOverlapRange]) -> [AttributedTranscriptRun] {
        func overlaps(_ start: Int, _ end: Int) -> Bool {
            overlapRanges.contains { start < $0.endMs && end > $0.startMs }
        }
        func normalized(_ value: String) -> String {
            value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let display = Word.displayWords(from: wordsWithInheritedAttribution)
        // A partial word list must never replace the complete utterance text.
        guard !display.isEmpty, text.isEmpty || normalized(display.map(\.text).joined(separator: " ")) == normalized(text) else {
            let overlapping = overlaps(startMs, endMs)
            let parent = speakerAttribution?.speakerIndex
            let conflictingOverride = words.contains {
                if let explicit = $0.speakerAttribution { return explicit.speakerIndex != parent }
                return false
            }
            return text.isEmpty ? [] : [AttributedTranscriptRun(text: text,
                speakerIndex: overlapping || conflictingOverride ? nil : parent, overlaps: overlapping)]
        }
        var result: [AttributedTranscriptRun] = []
        for word in display {
            let overlapping = overlaps(word.startMs, word.endMs)
            let index = overlapping ? nil : word.resolvedSpeakerIndex(in: speakers)
            if let last = result.last, last.speakerIndex == index, last.overlaps == overlapping {
                result[result.count - 1] = AttributedTranscriptRun(text: last.text + " " + word.text,
                    speakerIndex: index, overlaps: overlapping)
            } else {
                result.append(AttributedTranscriptRun(text: word.text, speakerIndex: index, overlaps: overlapping))
            }
        }
        return result
    }
}
