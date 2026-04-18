import Foundation

public enum TranscriptWriter {
    /// Writes a `<wav-stem>.txt` (plain transcript) and `<wav-stem>.json` (full structured)
    /// alongside the given WAV URL. Uses atomic writes (writes to temp + rename).
    public static func writeSiblings(transcript: SessionTranscript, nextTo wavURL: URL) throws {
        let stem = wavURL.deletingPathExtension().lastPathComponent
        let parent = wavURL.deletingLastPathComponent()

        let txtURL = parent.appendingPathComponent("\(stem).txt")
        let jsonURL = parent.appendingPathComponent("\(stem).json")

        let txtData = Data((transcript.joinedText + "\n").utf8)
        try txtData.write(to: txtURL, options: .atomic)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let jsonData = try encoder.encode(transcript)
        try jsonData.write(to: jsonURL, options: .atomic)
    }
}
