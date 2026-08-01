import Foundation
import HarcClient
import HarcCore

/// SRT / WebVTT rendering from stored word timings (#99).
///
/// Pure functions over a `SessionTranscript` — no filesystem. Cue
/// segmentation works on *display words* (SentencePiece tokens re-joined at
/// word boundaries, mirroring `ExportInputBuilder`) so cues never split
/// mid-word, then breaks cues on speaker change, silence gaps, a line-length
/// budget, and a duration cap.
public enum SubtitleExporter {

    public struct Cue: Equatable, Sendable {
        public let startMs: Int
        public let endMs: Int
        public let speaker: Int?
        public let text: String
    }

    // Two subtitle lines of ~42 chars is the classic broadcast budget.
    static let maxCueChars = 84
    static let maxCueMs = 5_000
    static let gapBreakMs = 800

    // MARK: - Cue building

    /// A display word with its time span: SentencePiece continuation tokens
    /// merged into the word they belong to.
    struct TimedWord {
        var text: String
        var startMs: Int
        var endMs: Int
    }

    static func displayWords(from words: [Word]) -> [TimedWord] {
        guard !words.isEmpty else { return [] }
        // Leading-space tokens mark word boundaries; bare tokens continue
        // the previous word. A transcript with no leading-space token at
        // all is plain word-per-entry (older sidecars, tests).
        let sentencePieceStyle = words.contains { $0.text.first?.isWhitespace == true }
        guard sentencePieceStyle else {
            return words.compactMap {
                let t = $0.text.trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : TimedWord(text: t, startMs: $0.startMs, endMs: $0.endMs)
            }
        }

        var out: [TimedWord] = []
        for token in words {
            let isBoundary = token.text.first?.isWhitespace == true
            let piece = token.text.trimmingCharacters(in: .whitespaces)
            if piece.isEmpty { continue }
            if isBoundary || out.isEmpty {
                out.append(TimedWord(text: piece, startMs: token.startMs, endMs: token.endMs))
            } else {
                out[out.count - 1].text += piece
                out[out.count - 1].endMs = token.endMs
            }
        }
        return out
    }

    public static func makeCues(
        words: [Word],
        speakers: [SpeakerSegment]
    ) -> [Cue] {
        let timed = displayWords(from: words)
        guard !timed.isEmpty else { return [] }

        func speaker(at ms: Int) -> Int? {
            speakers.first { ms >= $0.startMs && ms < $0.endMs }?.speaker
        }

        var cues: [Cue] = []
        var bucket: [TimedWord] = []
        var bucketSpeaker: Int? = nil

        func flush() {
            guard let first = bucket.first, let last = bucket.last else { return }
            cues.append(Cue(
                startMs: first.startMs,
                // A cue that ends the instant its last word does flickers;
                // hold at least 1s unless the next cue starts sooner (the
                // renderer clamps overlaps).
                endMs: max(last.endMs, first.startMs + 1_000),
                speaker: bucketSpeaker,
                text: bucket.map(\.text).joined(separator: " ")
            ))
            bucket = []
        }

        for word in timed {
            let mid = (word.startMs + word.endMs) / 2
            let wordSpeaker = speaker(at: mid) ?? bucketSpeaker
            let bucketChars = bucket.reduce(0) { $0 + $1.text.count + 1 }
            let shouldBreak: Bool
            if let last = bucket.last {
                shouldBreak = wordSpeaker != bucketSpeaker
                    || word.startMs - last.endMs > gapBreakMs
                    || bucketChars + word.text.count > maxCueChars
                    || word.endMs - bucket[0].startMs > maxCueMs
            } else {
                shouldBreak = false
            }
            if shouldBreak { flush() }
            if bucket.isEmpty { bucketSpeaker = wordSpeaker }
            bucket.append(word)
        }
        flush()

        // Clamp the 1s minimum hold so cues never overlap their successor.
        for i in 0..<max(0, cues.count - 1) where cues[i].endMs > cues[i + 1].startMs {
            cues[i] = Cue(
                startMs: cues[i].startMs,
                endMs: cues[i + 1].startMs,
                speaker: cues[i].speaker,
                text: cues[i].text
            )
        }
        return cues
    }

    // MARK: - Renderers

    public static func srt(cues: [Cue], speakerNames: [Int: String] = [:]) -> String {
        var lines: [String] = []
        for (i, cue) in cues.enumerated() {
            lines.append("\(i + 1)")
            lines.append("\(timestamp(cue.startMs, comma: true)) --> \(timestamp(cue.endMs, comma: true))")
            lines.append(cueText(cue, speakerNames: speakerNames))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func vtt(cues: [Cue], speakerNames: [Int: String] = [:]) -> String {
        var lines: [String] = ["WEBVTT", ""]
        for cue in cues {
            lines.append("\(timestamp(cue.startMs, comma: false)) --> \(timestamp(cue.endMs, comma: false))")
            lines.append(cueText(cue, speakerNames: speakerNames))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func cueText(_ cue: Cue, speakerNames: [Int: String]) -> String {
        guard let name = SpeakerLabel.displayLabel(for: cue.speaker, names: speakerNames) else {
            return cue.text
        }
        return "\(name): \(cue.text)"
    }

    static func timestamp(_ ms: Int, comma: Bool) -> String {
        let clamped = max(0, ms)
        let h = clamped / 3_600_000
        let m = (clamped / 60_000) % 60
        let s = (clamped / 1_000) % 60
        let frac = clamped % 1_000
        let sep = comma ? "," : "."
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, sep, frac)
    }
}
