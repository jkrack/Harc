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

    @Test("installRequired when summarizer not installed and nothing else qualifies")
    func installRequired() async {
        let rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        let state = SummaryCardState.resolve(
            recording: rec,
            isInFlight: false, isQueued: false, position: nil, totalInFlight: 0,
            isSummarizerInstalled: false, lastFailure: nil
        )
        #expect(state == .installRequired)
    }

    @Test("summary when summaryMarkdown is present")
    func summaryPresent() async {
        var rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        rec.summaryMarkdown = "s"
        let state = SummaryCardState.resolve(
            recording: rec,
            isInFlight: false, isQueued: false, position: nil, totalInFlight: 0,
            isSummarizerInstalled: true, lastFailure: nil
        )
        #expect(state == .summary)
    }

    @Test("failed when lastFailure is non-nil and no summary / queue state")
    func failed() async {
        let rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        let state = SummaryCardState.resolve(
            recording: rec,
            isInFlight: false, isQueued: false, position: nil, totalInFlight: 0,
            isSummarizerInstalled: true, lastFailure: "boom"
        )
        #expect(state == .failed(message: "boom"))
    }

    @Test("queued with position + totalInFlight when isQueued is true")
    func queued() async {
        let rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        let state = SummaryCardState.resolve(
            recording: rec,
            isInFlight: false, isQueued: true, position: 2, totalInFlight: 3,
            isSummarizerInstalled: true, lastFailure: nil
        )
        #expect(state == .queued(position: 2, totalInFlight: 3))
    }

    @Test("inFlight beats queued / summary / failed / installRequired / empty")
    func inFlightBeatsEverything() async {
        var rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        rec.summaryMarkdown = "s"
        let state = SummaryCardState.resolve(
            recording: rec,
            isInFlight: true, isQueued: true, position: 1, totalInFlight: 1,
            isSummarizerInstalled: false, lastFailure: "boom"
        )
        #expect(state == .inFlight)
    }

    @Test("summary beats failed when both are present (regenerate-failed doesn't hide existing summary)")
    func summaryBeatsFailed() async {
        var rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        rec.summaryMarkdown = "s"
        let state = SummaryCardState.resolve(
            recording: rec,
            isInFlight: false, isQueued: false, position: nil, totalInFlight: 0,
            isSummarizerInstalled: true, lastFailure: "boom"
        )
        #expect(state == .summary)
    }

    @Test("summary beats installRequired (keep showing existing summary even if active tier changes to uninstalled one)")
    func summaryBeatsInstallRequired() async {
        var rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        rec.summaryMarkdown = "s"
        let state = SummaryCardState.resolve(
            recording: rec,
            isInFlight: false, isQueued: false, position: nil, totalInFlight: 0,
            isSummarizerInstalled: false, lastFailure: nil
        )
        #expect(state == .summary)
    }

    @Test("failed beats installRequired")
    func failedBeatsInstallRequired() async {
        let rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        let state = SummaryCardState.resolve(
            recording: rec,
            isInFlight: false, isQueued: false, position: nil, totalInFlight: 0,
            isSummarizerInstalled: false, lastFailure: "boom"
        )
        #expect(state == .failed(message: "boom"))
    }
}
