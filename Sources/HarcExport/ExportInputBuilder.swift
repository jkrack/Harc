import Foundation
import HarcClient
import HarcCore
import HarcStore

/// Builds an `ExportInput` from a `Recording` by loading the on-disk
/// `SessionTranscript` JSON and collapsing words into speaker-attributed
/// segments. Falls back to `Recording.transcriptText` when the JSON is
/// missing or unreadable.
public enum ExportInputBuilder {
    /// The decoded JSON sidecar, when present and readable. Shared by the
    /// segment-collapsing path and the subtitle exporters, which need the
    /// raw word timings rather than collapsed segments.
    public static func loadTranscript(from recording: Recording) -> SessionTranscript? {
        guard let path = recording.jsonPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(SessionTranscript.self, from: data)
    }

    public static func build(from recording: Recording) -> ExportInput {
        let duration: Int? = recording.endedAt.map {
            max(0, Int($0.timeIntervalSince(recording.startedAt)))
        }
        let title = recording.displayTitle

        if let transcript = loadTranscript(from: recording) {
            let segments = collapseToSegments(transcript: transcript)
            return ExportInput(
                title: title,
                startedAt: recording.startedAt,
                durationSeconds: duration,
                tags: recording.tags,
                speakerNames: recording.speakerNames,
                segments: segments
            )
        }

        if let text = recording.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return ExportInput(
                title: title,
                startedAt: recording.startedAt,
                durationSeconds: duration,
                tags: recording.tags,
                speakerNames: recording.speakerNames,
                segments: [.init(speaker: nil, text: text)]
            )
        }

        return ExportInput(
            title: title,
            startedAt: recording.startedAt,
            durationSeconds: duration,
            tags: recording.tags,
            speakerNames: recording.speakerNames,
            segments: []
        )
    }

    /// Collapse `words` + `speakers` into contiguous same-speaker segments.
    /// If `speakers` is empty, emit a single `speaker: nil` segment.
    static func collapseToSegments(transcript: SessionTranscript) -> [ExportInput.Segment] {
        let overlaps = transcript.overlapRanges ?? []
        let warnings: [ExportInput.Segment] = overlaps.isEmpty ? [] : [
            .init(speaker: nil, text: "Overlapping voices detected. Speaker attribution may be incomplete.")
        ]
        guard (!transcript.speakers.isEmpty || !overlaps.isEmpty), !transcript.words.isEmpty else {
            let t = transcript.joinedText.trimmingCharacters(in: .whitespacesAndNewlines)
            return warnings + (t.isEmpty ? [] : [.init(speaker: nil, text: t)])
        }

        // Parakeet/FluidAudio emits SentencePiece-style tokens where a leading
        // space marks a word boundary (" for", " New") and a bare token is a
        // subword continuation ("ig" after " B" → "Big"). Naively joining with
        // " " between every token produces `" B" + " " + "ig" = " B ig"` and
        // doubled spaces on word boundaries. Mirror the detection/concat
        // strategy from TranscriptPlainTextRenderer.
        let sentencePieceStyle = transcript.words.contains { $0.text.first?.isWhitespace == true }

        var currentSpeaker: Int? = nil
        var currentOverlap = false
        var bucketText = ""
        var output: [ExportInput.Segment] = warnings

        func flush() {
            let t = bucketText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                output.append(.init(speaker: currentOverlap ? nil : currentSpeaker,
                                    text: currentOverlap ? "Overlapping voices: \(t)" : t))
            }
            bucketText = ""
        }

        let notices = UntranscribedAudioMarker.parse(in: transcript.joinedText)
        var noticeIndex = 0
        func emitNotices(through timestamp: Int) {
            while noticeIndex < notices.count, notices[noticeIndex].startMs <= timestamp {
                flush()
                currentSpeaker = nil
                currentOverlap = false
                output.append(.init(speaker: nil, text: notices[noticeIndex].text))
                noticeIndex += 1
            }
        }

        for word in transcript.words {
            emitNotices(through: word.startMs)
            let midpoint = (word.startMs + word.endMs) / 2
            let isOverlap = overlaps.contains {
                word.startMs < $0.endMs && max(word.startMs, word.endMs) > $0.startMs
                    || word.startMs == word.endMs && $0.startMs <= word.startMs && word.startMs < $0.endMs
            }
            let assigned: Int? = isOverlap ? nil : transcript.speakers.first { seg in
                midpoint >= seg.startMs && midpoint < seg.endMs
            }?.speaker ?? currentSpeaker

            if assigned != currentSpeaker || isOverlap != currentOverlap {
                flush()
                currentSpeaker = assigned
                currentOverlap = isOverlap
            }
            if sentencePieceStyle {
                bucketText += word.text
            } else if bucketText.isEmpty {
                bucketText = word.text
            } else {
                bucketText += " " + word.text
            }
        }
        flush()
        emitNotices(through: Int.max)

        if output.isEmpty {
            let t = transcript.joinedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                output.append(.init(
                    speaker: transcript.speakers.first?.speaker,
                    text: t
                ))
            }
        }
        return output
    }
}
