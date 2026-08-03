import Testing
import Foundation
@testable import HarcUI

private actor ControlledPostStopSleep {
    private var requested: Duration?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func sleep(for duration: Duration) async throws {
        requested = duration
        guard !isReleased else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
        try Task.checkCancellation()
    }

    func requestedDuration() -> Duration? { requested }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@Suite("PostStopTrayState")
@MainActor
struct PostStopTrayStateTests {

    @Test("starts hidden")
    func startsHidden() {
        let s = PostStopTrayState()
        #expect(s.isVisible == false)
        #expect(s.lastTranscript == nil)
        #expect(s.lastRecordingID == nil)
        #expect(s.lastWavPath == nil)
        #expect(s.lastOutcome == nil)
    }

    @Test("show() makes it visible with the given transcript and recording identity")
    func showVisible() {
        let s = PostStopTrayState()
        s.show(title: "Standup", transcript: "Hello world.", recordingID: 42, wavPath: "/tmp/standup.wav")
        #expect(s.isVisible == true)
        #expect(s.lastTranscript == "Hello world.")
        #expect(s.lastTitle == "Standup")
        #expect(s.lastRecordingID == 42)
        #expect(s.lastWavPath == "/tmp/standup.wav")
        #expect(s.lastOutcome?.kind == .savedSafely)
        #expect(s.lastOutcome?.title == "Saved safely")
    }

    @Test("showOutcome makes recovery visible even without transcript")
    func showOutcomeVisibleWithoutTranscript() {
        let s = PostStopTrayState()
        let outcome = StopOutcome.recoveryNeeded(detail: "Finalization timed out.")

        s.showOutcome(title: "Recovery needed", outcome: outcome)

        #expect(s.isVisible == true)
        #expect(s.lastTranscript == "")
        #expect(s.lastOutcome == outcome)
    }

    @Test("savedSafely outcome names durable artifact")
    func savedSafelyNamesArtifact() {
        let outcome = StopOutcome.savedSafely(title: "Standup", wavPath: "/tmp/2026-05-18/standup.wav")

        #expect(outcome.kind == .savedSafely)
        #expect(outcome.title == "Saved safely")
        #expect(outcome.detail == "Saved to standup.wav")
    }

    @Test("dismiss() hides immediately")
    func dismissHides() {
        let s = PostStopTrayState()
        s.show(title: "Standup", transcript: "x")
        s.dismiss()
        #expect(s.isVisible == false)
    }

    @Test("auto-fades after the configured TTL")
    func autoFade() async throws {
        let controlledSleep = ControlledPostStopSleep()
        let expectedDuration = Duration.milliseconds(50)
        let s = PostStopTrayState(
            visibleDuration: expectedDuration,
            sleep: { duration in try await controlledSleep.sleep(for: duration) }
        )
        s.show(title: "T", transcript: "t")
        #expect(s.isVisible == true)

        let deadline = ContinuousClock.now + .seconds(180)
        var requestedDuration: Duration?
        while requestedDuration == nil, ContinuousClock.now < deadline {
            requestedDuration = await controlledSleep.requestedDuration()
            if requestedDuration == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(requestedDuration == expectedDuration)
        #expect(s.isVisible == true, "the tray must remain visible until the configured sleep completes")

        await controlledSleep.release()
        while s.isVisible {
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(s.isVisible == false)
    }
}
