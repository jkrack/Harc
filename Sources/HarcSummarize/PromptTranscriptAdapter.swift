import Foundation
import HarcCore

/// Convert the HarcCore transcript primitives (joined text + per-word
/// timings + diarization segments + per-recording speaker-name overrides)
/// into a `PromptTranscript` ready for `SummaryPrompt.build`.
///
/// Pure — no I/O, no state. Mirrors `HarcClient.TranscriptPlainTextRenderer`
/// but emits structured `Utterance`s instead of joined paragraph strings.
public enum PromptTranscriptAdapter {

    /// Group words into contiguous same-speaker runs and emit one
    /// `Utterance` per run. Falls back to a single un-labeled utterance
    /// carrying `joinedText` when diarization is absent.
    public static func make(
        joinedText: String,
        words: [Word],
        speakers: [SpeakerSegment],
        speakerNameOverrides: [Int: String]
    ) -> PromptTranscript {
        let trimmedFallback = joinedText.trimmingCharacters(in: .whitespacesAndNewlines)

        // No diarization (or no timings to diarize against) → one utterance.
        guard !speakers.isEmpty, !words.isEmpty else {
            if trimmedFallback.isEmpty {
                return PromptTranscript(utterances: [])
            }
            return PromptTranscript(utterances: [
                .init(speaker: nil, text: trimmedFallback)
            ])
        }

        // Pick concat strategy per-transcript: SentencePiece style leaves a
        // leading space on continuation tokens; whole-word style has none
        // and we insert spaces ourselves.
        let sentencePieceStyle = words.contains { $0.text.first?.isWhitespace == true }

        var utterances: [PromptTranscript.Utterance] = []
        var currentSpeaker: Int? = nil
        var bucket = ""

        func flush() {
            let trimmed = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let label = currentSpeaker.flatMap { idx in
                    speakerNameOverrides[idx] ?? "Speaker \(idx + 1)"
                }
                utterances.append(.init(speaker: label, text: trimmed))
            }
            bucket = ""
        }

        for word in words {
            let midpoint = (word.startMs + word.endMs) / 2
            let assigned: Int?
            if let containing = speakers.first(where: {
                midpoint >= $0.startMs && midpoint < $0.endMs
            }) {
                assigned = containing.speaker
            } else if currentSpeaker != nil {
                assigned = currentSpeaker
            } else {
                assigned = speakers.min { a, b in
                    distance(midpoint, from: a) < distance(midpoint, from: b)
                }?.speaker
            }

            if assigned != currentSpeaker {
                flush()
                currentSpeaker = assigned
            }

            if sentencePieceStyle {
                bucket += word.text
            } else if bucket.isEmpty {
                bucket = word.text
            } else {
                bucket += " " + word.text
            }
        }
        flush()

        if utterances.isEmpty {
            if trimmedFallback.isEmpty {
                return PromptTranscript(utterances: [])
            }
            return PromptTranscript(utterances: [
                .init(speaker: nil, text: trimmedFallback)
            ])
        }
        return PromptTranscript(utterances: utterances)
    }

    private static func distance(_ point: Int, from seg: SpeakerSegment) -> Int {
        if point < seg.startMs { return seg.startMs - point }
        if point >= seg.endMs  { return point - seg.endMs + 1 }
        return 0
    }
}
