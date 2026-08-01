import Foundation
import HarcCore

/// Build one combined `PromptTranscript` from a session's member recordings.
///
/// Pure — no I/O, no store access. The caller resolves speaker names
/// (Person link > per-recording override > "Speaker N") *before* calling,
/// keyed by each part's own diarization indices. Cross-recording speaker
/// unification falls out of that resolution: when two parts both resolve
/// index→"Jason", the combined prompt reads as one speaker.
public enum SessionPromptAssembler {

    /// One member recording's transcript primitives plus resolved names.
    public struct Part: Sendable {
        public let joinedText: String
        public let words: [Word]
        public let speakers: [SpeakerSegment]
        /// Fully resolved display names per diarization index. Missing
        /// indices fall back to "Speaker N" inside the adapter.
        public let speakerNames: [Int: String]
        public let startedAt: Date

        public init(
            joinedText: String,
            words: [Word],
            speakers: [SpeakerSegment],
            speakerNames: [Int: String],
            startedAt: Date
        ) {
            self.joinedText = joinedText
            self.words = words
            self.speakers = speakers
            self.speakerNames = speakerNames
            self.startedAt = startedAt
        }
    }

    /// Concatenate parts in `startedAt` order, each prefixed by an
    /// un-labeled separator utterance ("— Recording started 2:04 PM —") so
    /// the model can attribute topic shifts to a new sitting. Parts that
    /// produce no utterances (empty transcript) are dropped, separator and
    /// all. A single-part session gets no separator — it would only burn
    /// prompt budget restating the timestamp already in the metadata.
    public static func make(parts: [Part]) -> PromptTranscript {
        let ordered = parts.sorted { $0.startedAt < $1.startedAt }

        var assembled: [(startedAt: Date, utterances: [PromptTranscript.Utterance])] = []
        for part in ordered {
            let transcript = PromptTranscriptAdapter.make(
                joinedText: part.joinedText,
                words: part.words,
                speakers: part.speakers,
                speakerNameOverrides: part.speakerNames
            )
            guard !transcript.utterances.isEmpty else { continue }
            assembled.append((part.startedAt, transcript.utterances))
        }

        guard assembled.count > 1 else {
            return PromptTranscript(utterances: assembled.first?.utterances ?? [])
        }

        var utterances: [PromptTranscript.Utterance] = []
        for (startedAt, partUtterances) in assembled {
            utterances.append(.init(
                speaker: nil,
                text: "— Recording started \(Self.timeFormatter.string(from: startedAt)) —"
            ))
            utterances.append(contentsOf: partUtterances)
        }
        return PromptTranscript(utterances: utterances)
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}
