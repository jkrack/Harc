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
