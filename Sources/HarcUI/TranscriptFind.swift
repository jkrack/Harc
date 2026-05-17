import Foundation

struct TranscriptSearchMatch: Equatable {
    let segmentID: UUID?
    let occurrenceIndex: Int
    let range: NSRange
}

enum TranscriptFind {
    static func matches(in text: String, query: String, segmentID: UUID? = nil) -> [TranscriptSearchMatch] {
        guard !query.isEmpty else { return [] }

        let source = text as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        var matches: [TranscriptSearchMatch] = []

        while searchRange.length > 0 {
            let found = source.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            )
            guard found.location != NSNotFound else { break }
            matches.append(TranscriptSearchMatch(
                segmentID: segmentID,
                occurrenceIndex: matches.count,
                range: found
            ))
            let nextLocation = found.location + max(found.length, 1)
            searchRange = NSRange(location: nextLocation, length: max(0, source.length - nextLocation))
        }

        return matches
    }
}
