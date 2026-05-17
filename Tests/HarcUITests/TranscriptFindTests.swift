import Foundation
import Testing
@testable import HarcUI

@Suite("TranscriptFind")
struct TranscriptFindTests {
    @Test("tracks multiple occurrences within one segment")
    func tracksMultipleOccurrencesWithinSegment() {
        let segmentID = UUID()

        let matches = TranscriptFind.matches(
            in: "Alex asked Alex to follow up with alex.",
            query: "alex",
            segmentID: segmentID
        )

        #expect(matches.map(\.segmentID) == [segmentID, segmentID, segmentID])
        #expect(matches.map(\.occurrenceIndex) == [0, 1, 2])
        #expect(matches.map(\.range.location) == [0, 11, 34])
    }

    @Test("flat transcript matches keep nil segment IDs")
    func flatTranscriptMatchesKeepNilSegmentIDs() {
        let matches = TranscriptFind.matches(in: "decision, Decision", query: "decision")

        #expect(matches.count == 2)
        #expect(matches.allSatisfy { $0.segmentID == nil })
        #expect(matches.map(\.occurrenceIndex) == [0, 1])
    }
}
