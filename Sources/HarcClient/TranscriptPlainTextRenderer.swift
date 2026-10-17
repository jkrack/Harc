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
    /// Renders a `SessionTranscript` to plain text.
    ///
    /// - Parameters:
    ///   - transcript: The session transcript to render.
    ///   - nameForSpeaker: Optional override closure. When provided, called for
    ///     every speaker index and its return value is used as the label prefix.
    ///     When `nil`, labels fall back to `"Speaker N+1"`. Keeping this as an
    ///     optional closure (rather than a HarcStore dependency) keeps HarcClient
    ///     pure: callers that have a resolved `[Int: String]` dictionary can pass
    ///     `{ dict[$0] ?? "Speaker \($0 + 1)" }` at the call site.
    public static func render(
        _ transcript: SessionTranscript,
        nameForSpeaker: ((Int) -> String)? = nil
    ) -> String {
        let joinedFallback = transcript.joinedText.trimmingCharacters(in: .whitespacesAndNewlines)

        let overlaps = transcript.overlapRanges ?? []
        let warning = "Overlapping voices detected. Speaker attribution may be incomplete."
        if let utterances = transcript.attributedUtterances, !utterances.isEmpty {
            if transcript.manualEditAt != nil {
                return overlaps.isEmpty ? joinedFallback : [warning, joinedFallback].filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
            let lines = utterances.flatMap { $0.displayRuns(speakers: transcript.speakers, overlapRanges: overlaps) }.map { run in
                if run.overlaps { return "Overlapping voices: \(run.text)" }
                if let index = run.speakerIndex {
                    return "\(nameForSpeaker?(index) ?? "Speaker \(index + 1)"): \(run.text)"
                }
                return run.text
            }
            let notices = UntranscribedAudioMarker.parse(in: joinedFallback).map(\.text)
                .filter { notice in !lines.contains(where: { $0.contains(notice) }) }
            return ((overlaps.isEmpty ? [] : [warning]) + lines + notices).joined(separator: "\n\n")
        }
        guard (!transcript.speakers.isEmpty || transcript.words.contains { $0.speakerAttribution != nil } || !overlaps.isEmpty), !transcript.words.isEmpty else {
            return overlaps.isEmpty ? joinedFallback : [warning, joinedFallback].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }

        let displayWords = Word.displayWords(from: transcript.words)

        var paragraphs: [String] = overlaps.isEmpty ? [] : [warning]
        var currentSpeaker: Int? = nil
        var currentOverlap = false
        var bucket = ""

        func flush() {
            let trimmed = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if currentOverlap {
                    paragraphs.append("Overlapping voices: \(trimmed)")
                } else if let s = currentSpeaker {
                    let label = nameForSpeaker?(s) ?? "Speaker \(s + 1)"
                    paragraphs.append("\(label): \(trimmed)")
                } else {
                    paragraphs.append(trimmed)
                }
            }
            bucket = ""
        }

        let notices = UntranscribedAudioMarker.parse(in: joinedFallback)
        var noticeIndex = 0
        func emitNotices(through timestamp: Int) {
            while noticeIndex < notices.count, notices[noticeIndex].startMs <= timestamp {
                flush()
                currentSpeaker = nil
                currentOverlap = false
                paragraphs.append(notices[noticeIndex].text)
                noticeIndex += 1
            }
        }

        for word in displayWords {
            emitNotices(through: word.startMs)
            let isOverlap = overlaps.contains {
                word.startMs < $0.endMs && max(word.startMs, word.endMs) > $0.startMs
                    || word.startMs == word.endMs && $0.startMs <= word.startMs && word.startMs < $0.endMs
            }
            let assigned: Int?
            if isOverlap {
                assigned = nil
            } else {
                assigned = word.resolvedSpeakerIndex(in: transcript.speakers)
            }

            if assigned != currentSpeaker || isOverlap != currentOverlap {
                flush()
                currentSpeaker = assigned
                currentOverlap = isOverlap
            }

            if bucket.isEmpty {
                bucket = word.text
            } else {
                bucket += " " + word.text
            }
        }
        flush()
        emitNotices(through: Int.max)

        return paragraphs.isEmpty ? joinedFallback : paragraphs.joined(separator: "\n\n")
    }

    private static func distance(_ point: Int, from seg: SpeakerSegment) -> Int {
        if point < seg.startMs { return seg.startMs - point }
        if point >= seg.endMs  { return point - seg.endMs + 1 }
        return 0
    }
}
