import Foundation
import Testing
@testable import HarcUI

@Suite("Literal full-context evidence partition")
struct ProjectEvidenceSourcePartitionTests {
    @Test(arguments: [
        ("repair", "repair", 0),
        ("🙂 repair\r\nCorrection: blocked.", "repair", 5),
        ("Correction: blocked.\nrepair", "repair", 21),
        ("repeat repeat", "repeat", 7),
        ("cafe\u{301} 👩‍👩‍👧‍👦 🇨🇦", "cafe\u{301}", 0),
        ("[literal](https://example.invalid) **words**", "**words**", 35)
    ])
    func partitionsPreserveEveryByte(item: (String, String, Int)) throws {
        let (source, quote, start) = item
        let parts = try #require(ProjectEvidenceSourcePartition.make(source: source, quote: quote,
            startUTF8: start, endUTF8: start + quote.utf8.count))
        #expect(Array((parts.before + parts.selected + parts.after).utf8) == Array(source.utf8))
        #expect(Array(parts.selected.utf8) == Array(quote.utf8))
    }
    @Test func rejectsInvalidBoundsAndDifferentBytes() {
        for (start, end) in [(-1, 2), (0, 99), (2, 1), (1, 1), (Int.max, Int.max), (0, Int.max)] {
            #expect(ProjectEvidenceSourcePartition.make(source: "abc", quote: "a", startUTF8: start, endUTF8: end) == nil)
        }
        #expect(ProjectEvidenceSourcePartition.make(source: "abc", quote: "", startUTF8: 0, endUTF8: 1) == nil)
        #expect(ProjectEvidenceSourcePartition.make(source: "abc", quote: "b", startUTF8: 0, endUTF8: 1) == nil)
        // Canonical equivalence must not authorize different bytes.
        #expect(ProjectEvidenceSourcePartition.make(source: "é", quote: "e\u{301}", startUTF8: 0, endUTF8: 2) == nil)
    }
    @Test func rejectsScalarAndGraphemeSplits() {
        #expect(ProjectEvidenceSourcePartition.make(source: "🙂", quote: "x", startUTF8: 1, endUTF8: 2) == nil)
        for (source, quote) in [("e\u{301}", "e"), ("👩‍👩‍👧‍👦", "👩"), ("🇨🇦", "🇨"), ("\r\n", "\r")] {
            #expect(ProjectEvidenceSourcePartition.make(source: source, quote: quote,
                startUTF8: 0, endUTF8: quote.utf8.count) == nil)
        }
    }
}
