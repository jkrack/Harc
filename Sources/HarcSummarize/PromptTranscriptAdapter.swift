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
        make(joinedText: joinedText, words: words, speakers: speakers,
             speakerNameOverrides: speakerNameOverrides, overlapRanges: nil)
    }

    public static func make(
        joinedText: String, words: [Word], speakers: [SpeakerSegment],
        speakerNameOverrides: [Int: String], overlapRanges: [SpeechOverlapRange]?,
        attributedUtterances: [AttributedTranscriptUtterance]? = nil, manualEditAt: Date? = nil
    ) -> PromptTranscript {
        let trimmedFallback = joinedText.trimmingCharacters(in: .whitespacesAndNewlines)

        let overlaps = overlapRanges ?? []
        let warning = "Overlapping voices detected. Speaker attribution may be incomplete."
        let warnings: [PromptTranscript.Utterance] = overlaps.isEmpty ? [] : [.init(speaker: nil, text: warning)]
        if manualEditAt != nil {
            return PromptTranscript(utterances: warnings + (trimmedFallback.isEmpty ? [] : [.init(speaker: nil, text: trimmedFallback)]))
        }
        if let attributedUtterances, !attributedUtterances.isEmpty {
            let runs = attributedUtterances.flatMap { $0.displayRuns(speakers: speakers, overlapRanges: overlaps) }
            let notices = UntranscribedAudioMarker.parse(in: trimmedFallback).map(\.text)
                .filter { notice in !runs.contains(where: { $0.text.contains(notice) }) }
            return PromptTranscript(utterances: warnings + runs.map { run in
                let label = run.overlaps ? "Overlapping voices" : run.speakerIndex.map { speakerNameOverrides[$0] ?? "Speaker \($0 + 1)" }
                return .init(speaker: label, text: run.text)
            } + notices.map { .init(speaker: nil, text: $0) })
        }
        // Keep the warning even when there are no usable word timings.
        guard (!speakers.isEmpty || words.contains { $0.speakerAttribution != nil } || !overlaps.isEmpty), !words.isEmpty else {
            if trimmedFallback.isEmpty {
                return PromptTranscript(utterances: warnings)
            }
            return PromptTranscript(utterances: warnings + [
                .init(speaker: nil, text: trimmedFallback)
            ])
        }

        // Pick concat strategy per-transcript: SentencePiece style leaves a
        // leading space on continuation tokens; whole-word style has none
        // and we insert spaces ourselves.
        let displayWords = Word.displayWords(from: words)

        var utterances: [PromptTranscript.Utterance] = warnings
        var currentSpeaker: Int? = nil
        var currentOverlap = false
        var bucket = ""

        func flush() {
            let trimmed = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let label = currentOverlap ? "Overlapping voices" : currentSpeaker.flatMap { idx in
                    speakerNameOverrides[idx] ?? "Speaker \(idx + 1)"
                }
                utterances.append(.init(speaker: label, text: trimmed))
            }
            bucket = ""
        }

        let notices = UntranscribedAudioMarker.parse(in: trimmedFallback)
        var noticeIndex = 0
        func emitNotices(through timestamp: Int) {
            while noticeIndex < notices.count, notices[noticeIndex].startMs <= timestamp {
                flush()
                currentSpeaker = nil
                currentOverlap = false
                utterances.append(.init(speaker: nil, text: notices[noticeIndex].text))
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
                assigned = word.resolvedSpeakerIndex(in: speakers)
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

        if utterances.isEmpty {
            if trimmedFallback.isEmpty {
                return PromptTranscript(utterances: warnings)
            }
            return PromptTranscript(utterances: warnings + [
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
