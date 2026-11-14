import Foundation
import HarcStore
import Testing
@testable import HarcUI

@Suite("Speaker review load generation")
struct SpeakerReviewLoadGenerationTests {
    private func recording() -> Recording {
        Recording(wavPath: "/tmp/synthetic-speaker-review.wav", startedAt: Date(timeIntervalSince1970: 1))
    }

    @Test func stalePostMutationCallbackCannotInvalidateCurrentRefresh() throws {
        let before = recording()
        var after = before
        after.speakerNames = [0: "New assignment"]
        var loads = SpeakerReviewLoadGeneration()
        let currentTicket = loads.begin(recording: after, selectedRecording: after, isCancelled: false)
        let current = try #require(currentTicket)
        let rejected = loads.begin(recording: before, selectedRecording: after, isCancelled: false)
        #expect(rejected == nil)
        #expect(loads.isCurrent(current, recording: after, selectedRecording: after, isCancelled: false))
    }

    @Test func cancelledCallbackCannotInvalidateCurrentRefresh() throws {
        let row = recording()
        var loads = SpeakerReviewLoadGeneration()
        let currentTicket = loads.begin(recording: row, selectedRecording: row, isCancelled: false)
        let current = try #require(currentTicket)
        let rejected = loads.begin(recording: row, selectedRecording: row, isCancelled: true)
        #expect(rejected == nil)
        #expect(loads.isCurrent(current, recording: row, selectedRecording: row, isCancelled: false))
    }

    @Test func newerValidRefreshSupersedesOlderRefresh() throws {
        let row = recording()
        var loads = SpeakerReviewLoadGeneration()
        let oldTicket = loads.begin(recording: row, selectedRecording: row, isCancelled: false)
        let old = try #require(oldTicket)
        let newTicket = loads.begin(recording: row, selectedRecording: row, isCancelled: false)
        let new = try #require(newTicket)
        #expect(!loads.isCurrent(old, recording: row, selectedRecording: row, isCancelled: false))
        #expect(loads.isCurrent(new, recording: row, selectedRecording: row, isCancelled: false))
    }

    @Test func completionStillRejectsChangedSelectionRowAndCancellation() throws {
        let row = recording()
        var changed = row
        changed.title = "Changed while loading"
        var loads = SpeakerReviewLoadGeneration()
        let loadTicket = loads.begin(recording: row, selectedRecording: row, isCancelled: false)
        let load = try #require(loadTicket)
        #expect(!loads.isCurrent(load, recording: row, selectedRecording: changed, isCancelled: false))
        #expect(!loads.isCurrent(load, recording: row, selectedRecording: nil, isCancelled: false))
        #expect(!loads.isCurrent(load, recording: row, selectedRecording: row, isCancelled: true))
    }
}
