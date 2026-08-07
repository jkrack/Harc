import Foundation

/// Rewrites only the label at the start of diarized transcript turns.
///
/// The editable transcript is intentionally plain text, while speaker identity
/// lives separately in the store.  Matching turns by their ordered diarization
/// indices lets two different clusters resolve to the same Person without
/// losing which cluster produced each paragraph.
enum TranscriptSpeakerLabelRewriter {
    static func rewrite(
        _ text: String,
        turnSpeakerIndices: [Int],
        previousLabels: [Int: String],
        resolvedLabels: [Int: String]
    ) -> String {
        guard !text.isEmpty, !turnSpeakerIndices.isEmpty else { return text }

        var lines = text.components(separatedBy: "\n")
        let knownLabels = Set(previousLabels.values)
            .union(resolvedLabels.values)
            .union(turnSpeakerIndices.map { "Speaker \($0 + 1)" })

        let candidateLines = lines.indices.filter { index in
            guard let head = labelHead(in: lines[index]) else { return false }
            return knownLabels.contains(head) || defaultSpeakerIndex(in: head) != nil
        }

        // A generated Harc transcript has one labeled paragraph per ordered
        // diarization turn.  This path is unambiguous even when Speaker 1 and
        // Speaker 4 both resolve to the same Person name.
        if candidateLines.count == turnSpeakerIndices.count {
            for (lineIndex, speakerIndex) in zip(candidateLines, turnSpeakerIndices) {
                lines[lineIndex] = replacingHead(
                    in: lines[lineIndex],
                    with: resolvedLabels[speakerIndex] ?? "Speaker \(speakerIndex + 1)"
                )
            }
            return lines.joined(separator: "\n")
        }

        // Tolerant fallback for manually restructured transcripts: only
        // rewrite heads whose speaker index can still be identified exactly.
        let uniquePrevious = Dictionary(grouping: previousLabels, by: \.value)
            .compactMapValues { entries in entries.count == 1 ? entries[0].key : nil }
        for index in lines.indices {
            guard let head = labelHead(in: lines[index]) else { continue }
            let speakerIndex = defaultSpeakerIndex(in: head) ?? uniquePrevious[head]
            guard let speakerIndex else { continue }
            lines[index] = replacingHead(
                in: lines[index],
                with: resolvedLabels[speakerIndex] ?? "Speaker \(speakerIndex + 1)"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func labelHead(in line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let distance = line.distance(from: line.startIndex, to: colon)
        guard distance <= 60 else { return nil }
        let head = line[..<colon].trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? nil : head
    }

    private static func replacingHead(in line: String, with label: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return line }
        let leading = line.prefix { $0.isWhitespace }
        return String(leading) + label + line[colon...]
    }

    private static func defaultSpeakerIndex(in label: String) -> Int? {
        guard label.hasPrefix("Speaker "),
              let number = Int(label.dropFirst("Speaker ".count)),
              number > 0 else { return nil }
        return number - 1
    }
}
