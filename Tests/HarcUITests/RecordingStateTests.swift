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

    @Test("deferred stop clears the previous standalone result")
    func markDeferredStop() {
        let state = RecordingState()
        let oldWavURL = URL(fileURLWithPath: "/tmp/previous-standalone.wav")
        state.markStopped(wavURL: oldWavURL, txtURL: nil, jsonURL: nil)
        state.markStarted(at: Date())
        state.livePreviewText = "outbox capture"

        state.markDeferredStop()

        #expect(state.isRecording == false)
        #expect(state.isPreparing == false)
        #expect(state.recordingStartedAt == nil)
        #expect(state.livePreviewText.isEmpty)
        #expect(state.lastResult == nil)
    }
}

@Suite("Recording stop presentation")
@MainActor
struct RecordingStopPresentationTests {
    @Test("Stop freezes the display without releasing capture ownership")
    func freezesUntilFinalization() {
        let state = RecordingState()
        let start = Date(timeIntervalSince1970: 1_000)
        state.markStarted(at: start)
        #expect(state.elapsedText(at: start.addingTimeInterval(65)) == "1:05")
        state.markStopRequested(at: start.addingTimeInterval(65))
        #expect(state.isStopping)
        #expect(state.finishingElapsedText == "1:05")
        #expect(state.isRecording)
        #expect(state.isActiveOrPreparing)
        #expect(state.elapsedText(at: start.addingTimeInterval(600)) == "1:05")
        // A repeated stop cannot move the boundary forward.
        state.markStopRequested(at: start.addingTimeInterval(120))
        #expect(state.stopRequestedAt == start.addingTimeInterval(65))
        #expect(state.elapsedText(at: start.addingTimeInterval(900)) == "1:05")
    }

    @Test("Stop during preparation survives capture startup")
    func preparingStop() {
        let state = RecordingState()
        let requested = Date(timeIntervalSince1970: 1_000)
        state.markPreparing()
        state.markStopRequested(at: requested)
        state.markStarted(at: requested.addingTimeInterval(2))
        #expect(state.isStopping)
        #expect(state.isRecording)
        #expect(state.elapsedText(at: requested.addingTimeInterval(60)) == "0:00")
    }

    @Test("All completion paths clear the stop boundary")
    func completionClearsBoundary() {
        for completion in 0..<3 {
            let state = RecordingState()
            let start = Date(timeIntervalSince1970: 1_000)
            state.markStarted(at: start)
            state.markStopRequested(at: start.addingTimeInterval(60))
            let bridge = HarcAppBridge(recordingState: state, trayState: PostStopTrayState())
            bridge.beginRecordingStop()
            switch completion {
            case 0: state.markStopped(wavURL: URL(fileURLWithPath: "/tmp/synthetic.wav"), txtURL: nil, jsonURL: nil)
            case 1: state.markDeferredStop()
            default: state.markIdle()
            }
            #expect(!state.isStopping)
            #expect(bridge.recordingStopInFlight)
            #expect(state.finishingElapsedText == nil)
            #expect(!state.isActiveOrPreparing)
            #expect(state.elapsedText(at: start.addingTimeInterval(100)) == "0:00")
            state.markPreparing()
            state.markStarted(at: start.addingTimeInterval(120))
            #expect(state.elapsedText(at: start.addingTimeInterval(180)) == "1:00")
        }
    }

    @Test("Idle stop is ignored and a new attempt clears stale presentation")
    func newAttempt() {
        let state = RecordingState()
        state.markStopRequested()
        #expect(!state.isStopping)
        state.markPreparing()
        state.markStopRequested()
        state.markPreparing()
        #expect(!state.isStopping)
    }
}
