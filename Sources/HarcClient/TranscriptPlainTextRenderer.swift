import Foundation
import HarcCore

/// Renders a `SessionTranscript` to a plain-text blob for the `<stem>.txt`
/// sibling and clipboard paste.
///
/// Shape:
///   - With diarization: one paragraph per contiguous same-speaker run,
///     prefixed `Speaker N: `, separated by blank lines.
///   - Without diarization (no speaker segments or no word timings):
///     `joinedText` as a single paragraph.
///
/// Word tokens arrive in one of two styles and the renderer picks the
/// concat strategy per-transcript:
///   - SentencePiece-style (at least one token has a leading space —
///     `" te"`, `"e"`, `" it"`): tokens are concatenated verbatim. A
///     leading space marks a word boundary; a bare token is a subword
///     continuation.
///   - Whole-word (no token has a leading space — `"Hello"`, `"there"`):
///     tokens are joined with a single space.
///
/// The word-to-speaker assignment + same-speaker run grouping is mirrored
/// in `HarcSummarize.PromptTranscriptAdapter`; if you fix a bug in one,
/// fix the same bug in the other.
public enum TranscriptPlainTextRenderer {
    public static func render(_ transcript: SessionTranscript) -> String {
        let joinedFallback = transcript.joinedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !transcript.speakers.isEmpty, !transcript.words.isEmpty else {
            return joinedFallback
        }

        let sentencePieceStyle = transcript.words.contains { $0.text.first?.isWhitespace == true }

        var paragraphs: [String] = []
        var currentSpeaker: Int? = nil
        var bucket = ""

        func flush() {
            let trimmed = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let s = currentSpeaker {
                    paragraphs.append("Speaker \(s + 1): \(trimmed)")
                } else {
                    paragraphs.append(trimmed)
                }
            }
            bucket = ""
        }

        for word in transcript.words {
            let midpoint = (word.startMs + word.endMs) / 2
            let assigned: Int?
            if let containing = transcript.speakers.first(where: {
                midpoint >= $0.startMs && midpoint < $0.endMs
            }) {
                assigned = containing.speaker
            } else if currentSpeaker != nil {
                // Word fell in a between-segment gap; keep current speaker
                // rather than inserting a bogus turn.
                assigned = currentSpeaker
            } else {
                // Leading-edge word: word ends before the first segment
                // starts. Snap to the nearest segment so the first turn is
                // labeled instead of dropping a speaker-less paragraph.
                assigned = transcript.speakers.min { a, b in
                    Self.distance(midpoint, from: a) < Self.distance(midpoint, from: b)
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

        return paragraphs.isEmpty ? joinedFallback : paragraphs.joined(separator: "\n\n")
    }

    private static func distance(_ point: Int, from seg: SpeakerSegment) -> Int {
        if point < seg.startMs { return seg.startMs - point }
        if point >= seg.endMs  { return point - seg.endMs + 1 }
        return 0
    }
}
