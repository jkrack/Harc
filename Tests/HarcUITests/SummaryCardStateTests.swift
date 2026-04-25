import Testing
import Foundation
import HarcStore
@testable import HarcUI

@MainActor
@Suite("SummaryCardState")
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

    @Test("isStale false when summarySourceWordCount is nil")
    func isStaleNilSource() async {
        var rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date(), transcriptText: "hello world")
        rec.summarySourceWordCount = nil
        #expect(SummaryCardState.isStale(recording: rec) == false)
    }

    @Test("isStale false when transcriptText is nil")
    func isStaleNilTranscript() async {
        var rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        rec.summarySourceWordCount = 100
        rec.transcriptText = nil
        #expect(SummaryCardState.isStale(recording: rec) == false)
    }

    @Test("isStale false when word count delta is 5% or less")
    func isStaleWithinTolerance() async {
        var rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        rec.summarySourceWordCount = 100
        rec.transcriptText = Array(repeating: "word", count: 100).joined(separator: " ")
        #expect(SummaryCardState.isStale(recording: rec) == false)
        rec.transcriptText = Array(repeating: "word", count: 105).joined(separator: " ")
        #expect(SummaryCardState.isStale(recording: rec) == false)
    }

    @Test("isStale true when word count delta exceeds 5%")
    func isStaleBeyondTolerance() async {
        var rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        rec.summarySourceWordCount = 100
        rec.transcriptText = Array(repeating: "word", count: 110).joined(separator: " ")   // 10 %
        #expect(SummaryCardState.isStale(recording: rec) == true)
        rec.transcriptText = Array(repeating: "word", count: 80).joined(separator: " ")    // 20 %
        #expect(SummaryCardState.isStale(recording: rec) == true)
    }
}
