import Foundation

/// Presentation-only partition. Byte fidelity is not semantic verification.
/// Invalid or grapheme-splitting selections must render the original plain source.
struct ProjectEvidenceSourcePartition: Equatable {
    let before: String
    let selected: String
    let after: String

    static func make(source: String, quote: String, startUTF8: Int, endUTF8: Int) -> Self? {
        let bytes = Array(source.utf8)
        guard startUTF8 >= 0, endUTF8 > startUTF8, endUTF8 <= bytes.count,
              !quote.isEmpty else { return nil }
        // Character boundaries, not merely scalar boundaries: never split a
        // combining mark, emoji ZWJ sequence, flag or CRLF grapheme for emphasis.
        var boundaries: Set<Int> = [0]
        var offset = 0
        for character in source {
            offset += character.utf8.count
            boundaries.insert(offset)
        }
        guard boundaries.contains(startUTF8), boundaries.contains(endUTF8),
              Array(bytes[startUTF8..<endUTF8]) == Array(quote.utf8),
              let before = String(bytes: bytes[..<startUTF8], encoding: .utf8),
              let selected = String(bytes: bytes[startUTF8..<endUTF8], encoding: .utf8),
              let after = String(bytes: bytes[endUTF8...], encoding: .utf8),
              Array((before + selected + after).utf8) == bytes else { return nil }
        return Self(before: before, selected: selected, after: after)
    }
}
