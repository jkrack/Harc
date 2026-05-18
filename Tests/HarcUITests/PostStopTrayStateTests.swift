import Testing
import Foundation
@testable import HarcUI

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
        let s = PostStopTrayState(visibleDuration: .milliseconds(50))
        s.show(title: "T", transcript: "t")
        #expect(s.isVisible == true)
        try await Task.sleep(for: .milliseconds(120))
        #expect(s.isVisible == false)
    }
}
