import Testing
import Foundation
import HarcCore
@testable import HarcUI

@Suite("RecordingState")
@MainActor
struct RecordingStateTests {
    @Test("starts idle")
    func startsIdle() {
        let state = RecordingState()
        #expect(state.isRecording == false)
        #expect(state.recordingStartedAt == nil)
        #expect(state.livePreviewText.isEmpty)
        #expect(state.lastResult == nil)
    }

    @Test("markStarted sets isRecording and startedAt")
    func markStarted() {
        let state = RecordingState()
        let now = Date()
        state.markStarted(at: now)
        #expect(state.isRecording == true)
        #expect(state.recordingStartedAt == now)
        #expect(state.livePreviewText.isEmpty)
    }

    @Test("markStopped resets recording flags and stores result URL")
    func markStopped() {
        let state = RecordingState()
        state.markStarted(at: Date())
        state.livePreviewText = "partial transcript"

        let wavURL = URL(fileURLWithPath: "/tmp/fake.wav")
        state.markStopped(wavURL: wavURL, txtURL: nil, jsonURL: nil)

        #expect(state.isRecording == false)
        #expect(state.recordingStartedAt == nil)
        #expect(state.livePreviewText.isEmpty)
        #expect(state.lastResult?.wavURL == wavURL)
    }
}
