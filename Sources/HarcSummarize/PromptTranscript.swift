import Foundation

/// Input to `SummaryPrompt.build`. A flat list of utterances; each may
/// carry a speaker label (when diarization is on) or be `nil` for solo
/// dictation. Decoupled from `HarcClient.SessionTranscript` on purpose
/// — Stage 1 doesn't depend on the rest of the audio pipeline; an
/// adapter from `SessionTranscript` ships in Stage 2 alongside the
/// service that consumes it.
public struct PromptTranscript: Equatable, Sendable {
    public struct Utterance: Equatable, Sendable {
        public let speaker: String?
        public let text: String

        public init(speaker: String?, text: String) {
            self.speaker = speaker
            self.text = text
        }
    }

    public let utterances: [Utterance]

    public init(utterances: [Utterance]) {
        self.utterances = utterances
    }
}
