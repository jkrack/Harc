import Combine
import Foundation
import Testing
@testable import HarcUI

@Suite("Recording meter isolation")
@MainActor
struct RecordingMeterStateTests {
    @Test("meter pulses do not publish broad Library bridge changes")
    func meterUpdatesStayNarrow() {
        let bridge = HarcAppBridge(recordingState: RecordingState(), trayState: PostStopTrayState())
        var broadChanges = 0
        var meterChanges = 0
        let broad = bridge.objectWillChange.sink { broadChanges += 1 }
        let narrow = bridge.recordingMeters.objectWillChange.sink { meterChanges += 1 }
        defer { broad.cancel(); narrow.cancel() }

        for index in 1...100 {
            bridge.amplitudeHistory = [Float(index) / 100]
            bridge.microphoneAmplitudeHistory = [Float(index) / 200]
            bridge.autoStopMicDb = -Float(index)
            bridge.autoStopSystemDb = -Float(index) / 2
        }

        #expect(broadChanges == 0)
        #expect(meterChanges == 200)
        #expect(bridge.recordingMeters.amplitudeHistory == [1])
        #expect(bridge.recordingMeters.microphoneAmplitudeHistory == [0.5])
        #expect(bridge.autoStopMicDb == -100)
        #expect(bridge.autoStopSystemDb == -50)
    }

    @Test("semantic recording and safety state still publishes through bridge")
    func semanticStateStillPublishes() {
        let bridge = HarcAppBridge(recordingState: RecordingState(), trayState: PostStopTrayState())
        var changes = 0
        let observation = bridge.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        bridge.beginRecordingStop()
        bridge.autoStopPhase = .warning(secondsLeft: 3, reason: .silence)
        bridge.captureIntegrityWarning = "Synthetic warning"
        #expect(changes == 3)
        #expect(bridge.recordingStopInFlight)
        #expect(bridge.autoStopPhase == .warning(secondsLeft: 3, reason: .silence))
    }

    @Test("unchanged visual frames are deduplicated without sharing microphone signal")
    func duplicateFrames() {
        let meters = RecordingMeterState()
        var changes = 0
        let observation = meters.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        meters.setAmplitudeHistory([0.8])
        meters.setMicrophoneAmplitudeHistory([0])
        meters.setAmplitudeHistory([0.8])
        meters.setMicrophoneAmplitudeHistory([0])
        #expect(changes == 2)
        #expect(meters.amplitudeHistory == [0.8])
        #expect(meters.microphoneAmplitudeHistory == [0])
        // Growing silent history remains observable for the no-signal timer.
        meters.setMicrophoneAmplitudeHistory([0, 0])
        #expect(changes == 3)
    }

    @Test("each completed amplitude window publishes once, even after capacity")
    func onePublicationPerWindow() {
        let controller = AutoStopController()
        let start = Date(timeIntervalSince1970: 1_000)
        controller.testingBegin(startedAt: start)
        var combinedFrames = 0
        var microphoneFrames = 0
        let combined = controller.$amplitudeHistory.dropFirst().sink { _ in combinedFrames += 1 }
        let microphone = controller.$microphoneAmplitudeHistory.dropFirst().sink { _ in microphoneFrames += 1 }
        defer { combined.cancel(); microphone.cancel() }

        for index in 1...110 {
            controller.testingConsume(
                smoothedDb: -10, micDb: -.infinity, systemDb: -10,
                now: start.addingTimeInterval(Double(index) * 0.11)
            )
        }
        #expect(combinedFrames == 110)
        #expect(microphoneFrames == 110)
        #expect(controller.amplitudeHistory.count == AutoStopController.amplitudeCapacity)
        #expect(controller.microphoneAmplitudeHistory.count == AutoStopController.amplitudeCapacity)
        #expect(controller.microphoneAmplitudeHistory.allSatisfy { $0 == 0 })
        #expect((controller.amplitudeHistory.last ?? 0) > 0.8)
    }
}
