import Foundation
import HarcClient
import HarcCore
import HarcStore

/// Builds an `ExportInput` from a `Recording` by loading the on-disk
/// `SessionTranscript` JSON and collapsing words into speaker-attributed
/// segments. Falls back to `Recording.transcriptText` when the JSON is
/// missing or unreadable.
public enum ExportInputBuilder {
    public static func build(from recording: Recording) -> ExportInput {
        let duration: Int? = recording.endedAt.map {
            max(0, Int($0.timeIntervalSince(recording.startedAt)))
        }
        let title = recording.displayTitle

        if let path = recording.jsonPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            if let transcript = try? decoder.decode(SessionTranscript.self, from: data) {
                let segments = collapseToSegments(transcript: transcript)
                return ExportInput(
                    title: title,
                    startedAt: recording.startedAt,
                    durationSeconds: duration,
                    segments: segments
                )
            }
        }

        if let text = recording.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return ExportInput(
                title: title,
                startedAt: recording.startedAt,
                durationSeconds: duration,
                segments: [.init(speaker: nil, text: text)]
            )
        }

        return ExportInput(
            title: title,
            startedAt: recording.startedAt,
            durationSeconds: duration,
            segments: []
        )
    }

    /// Collapse `words` + `speakers` into contiguous same-speaker segments.
    /// If `speakers` is empty, emit a single `speaker: nil` segment.
    static func collapseToSegments(transcript: SessionTranscript) -> [ExportInput.Segment] {
        guard !transcript.speakers.isEmpty else {
            let t = transcript.joinedText.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : [.init(speaker: nil, text: t)]
        }

        var currentSpeaker: Int? = nil
        var bucketText = ""
        var output: [ExportInput.Segment] = []

        func flush() {
            let t = bucketText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                output.append(.init(speaker: currentSpeaker, text: t))
            }
            bucketText = ""
        }

        for word in transcript.words {
            let midpoint = (word.startMs + word.endMs) / 2
            let assigned = transcript.speakers.first { seg in
                midpoint >= seg.startMs && midpoint < seg.endMs
            }?.speaker ?? currentSpeaker

            if assigned != currentSpeaker {
                flush()
                currentSpeaker = assigned
            }
            if !bucketText.isEmpty { bucketText += " " }
            bucketText += word.text
        }
        flush()

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
