import Foundation

/// Projects canonical speaker labels into the plain-text transcript returned
/// by the Host without mutating the stored transcript itself.
public enum SpeakerTranscriptLabelProjector {
    public static func project(
        _ transcript: String,
        labels: [SpeakerLabel]
    ) -> String {
        guard !transcript.isEmpty, !labels.isEmpty else { return transcript }
        let names = Dictionary(uniqueKeysWithValues: labels.map {
            (Int($0.speakerIndex), $0.displayName)
        })
        return transcript.components(separatedBy: "\n").map { line in
            guard let colon = line.firstIndex(of: ":") else { return line }
            let head = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard head.hasPrefix("Speaker "),
                  let number = Int(head.dropFirst("Speaker ".count)),
                  number > 0,
                  let name = names[number - 1] else { return line }
            let leading = line.prefix { $0.isWhitespace }
            return String(leading) + name + line[colon...]
        }.joined(separator: "\n")
    }
}
