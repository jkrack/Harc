import Foundation

/// Harc-generated failure notices are not speech and must not receive a speaker name.
/// Parse only the exact format emitted by failed-chunk publication, retaining its text.
public struct UntranscribedAudioMarker: Sendable, Equatable {
    public let startMs: Int
    public let endMs: Int
    public let text: String

    public static func text(startMs: Int, endMs: Int) -> String {
        func stamp(_ ms: Int) -> String {
            let seconds = ms / 1000
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        return "[\(stamp(startMs))–\(stamp(endMs)) could not be transcribed — Re-transcribe in Settings → Transcription repairs this from the saved audio]"
    }

    public static func parse(in text: String) -> [Self] {
        let pattern = #"\[(\d+):(\d{2})–(\d+):(\d{2}) could not be transcribed — Re-transcribe in Settings → Transcription repairs this from the saved audio\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            func time(_ minuteGroup: Int) -> Int? {
                guard let minutesRange = Range(match.range(at: minuteGroup), in: text),
                      let secondsRange = Range(match.range(at: minuteGroup + 1), in: text),
                      let minutes = Int(text[minutesRange]), let seconds = Int(text[secondsRange]),
                      seconds < 60, minutes <= (Int.max - 59_000) / 60_000 else { return nil }
                return minutes * 60_000 + seconds * 1000
            }
            guard let start = time(1), let end = time(3), end >= start,
                  let range = Range(match.range, in: text) else { return nil }
            return Self(startMs: start, endMs: end, text: String(text[range]))
        }.sorted { $0.startMs < $1.startMs }
    }
}
