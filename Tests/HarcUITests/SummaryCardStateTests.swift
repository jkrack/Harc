import Testing
import Foundation
import HarcStore
import HarcModels
@testable import HarcSummarize
@testable import HarcUI

@MainActor
@Suite("SummaryCardState.resolve")
struct SummaryCardStateTests {

    @Test("empty when summary nil, not queued, installed, no failure")
    func empty() async {
        let rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        let state = SummaryCardState.resolve(
            recording: rec,
            isInFlight: false,
            isQueued: false,
            position: nil,
            totalInFlight: 0,
            isSummarizerInstalled: true,
            lastFailure: nil
        )
        #expect(state == .empty)
    }
}
