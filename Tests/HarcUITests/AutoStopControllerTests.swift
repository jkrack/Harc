import Testing
import Foundation
@testable import HarcUI

@Suite("AutoStopController")
@MainActor
struct AutoStopControllerTests {
    private func controller(
        silenceEnabled: Bool = true,
        silenceThresholdSeconds: TimeInterval = 10,
        hardCapEnabled: Bool = false,
        hardCapSeconds: TimeInterval = 60,
        warningSeconds: Int = 5,
        stallSeconds: TimeInterval = 30
    ) -> AutoStopController {
        AutoStopController(config: AutoStopController.Config(
            silenceEnabled: silenceEnabled,
            silenceThresholdSeconds: silenceThresholdSeconds,
            silenceDbCeiling: -50,
            hardCapEnabled: hardCapEnabled,
            hardCapSeconds: hardCapSeconds,
            warningSeconds: warningSeconds,
            stallSeconds: stallSeconds
        ))
    }

    @Test("silent audio enters countdown, updates seconds left, then auto-stops")
    func silenceCountdownThenStop() {
        let started = Date(timeIntervalSince1970: 1_000)
        let c = controller()
        var stopped: AutoStopController.StopReason?
        c.onAutoStop = { stopped = $0 }
        c.testingBegin(startedAt: started)

        c.testingTick(now: started.addingTimeInterval(9))
        #expect(c.phase == .watching)

        c.testingTick(now: started.addingTimeInterval(10))
        #expect(c.phase == .warning(secondsLeft: 5, reason: .silence))

        c.testingTick(now: started.addingTimeInterval(12))
        #expect(c.phase == .warning(secondsLeft: 3, reason: .silence))

        c.testingTick(now: started.addingTimeInterval(16))
        #expect(stopped == .silence)
    }

    // MARK: - Capture stall vs. genuine silence
    //
    // These two cases look identical to the old silence rule — `lastNonSilentAt`
    // stops advancing either way — but they mean opposite things to the user.
    // A quiet room is working as intended; a dead pipeline means Harc is no
    // longer recording the meeting and said nothing about it.

    @Test("a quiet room still delivering level ticks reports silence, not a stall")
    func quietRoomIsNotAStall() {
        let started = Date(timeIntervalSince1970: 5_000)
        // Stall window deliberately shorter than the silence window, matching the
        // shipped defaults (30 s vs 5 min), so if the two were confused the stall
        // would win and this test would catch it.
        let c = controller(silenceThresholdSeconds: 60, stallSeconds: 10)
        var stopped: AutoStopController.StopReason?
        c.onAutoStop = { stopped = $0 }
        c.testingBegin(startedAt: started)

        // Silence is still audio: the mic keeps delivering buffers below the
        // ceiling, so ticks keep arriving throughout.
        for second in stride(from: 1, through: 59, by: 1) {
            c.testingConsume(smoothedDb: -60, now: started.addingTimeInterval(Double(second)))
        }

        c.testingTick(now: started.addingTimeInterval(59))
        #expect(c.phase == .watching)

        c.testingTick(now: started.addingTimeInterval(60))
        #expect(c.phase == .warning(secondsLeft: 5, reason: .silence))

        c.testingTick(now: started.addingTimeInterval(66))
        #expect(stopped == .silence)
    }

    @Test("ticks drying up reports captureStalled rather than blaming a quiet room")
    func deadPipelineReportsStall() {
        let started = Date(timeIntervalSince1970: 6_000)
        let c = controller(silenceThresholdSeconds: 60, stallSeconds: 10)
        var stopped: AutoStopController.StopReason?
        c.onAutoStop = { stopped = $0 }
        c.testingBegin(startedAt: started)

        // Audio flows for 5 s, then the pipeline dies — no more ticks at all.
        c.testingConsume(smoothedDb: -20, now: started.addingTimeInterval(5))

        c.testingTick(now: started.addingTimeInterval(14))
        #expect(c.phase == .watching)

        c.testingTick(now: started.addingTimeInterval(15))
        #expect(c.phase == .warning(secondsLeft: 5, reason: .captureStalled))

        c.testingTick(now: started.addingTimeInterval(21))
        #expect(stopped == .captureStalled)
    }

    @Test("a stall is caught even when silence auto-stop is switched off")
    func stallDetectedWithSilenceDisabled() {
        let started = Date(timeIntervalSince1970: 7_000)
        // With silence off and no stall rule, this recording used to run to the
        // hard cap writing nothing while the UI showed "Recording".
        let c = controller(silenceEnabled: false, stallSeconds: 10)
        var stopped: AutoStopController.StopReason?
        c.onAutoStop = { stopped = $0 }
        c.testingBegin(startedAt: started)

        c.testingConsume(smoothedDb: -20, now: started.addingTimeInterval(2))

        c.testingTick(now: started.addingTimeInterval(12))
        #expect(c.phase == .warning(secondsLeft: 5, reason: .captureStalled))

        c.testingTick(now: started.addingTimeInterval(18))
        #expect(stopped == .captureStalled)
    }

    @Test("recovered ticks clear the stall warning instead of stopping")
    func recoveredCaptureClearsStallWarning() {
        let started = Date(timeIntervalSince1970: 8_000)
        let c = controller(silenceThresholdSeconds: 600, stallSeconds: 10)
        var stopped: AutoStopController.StopReason?
        c.onAutoStop = { stopped = $0 }
        c.testingBegin(startedAt: started)

        c.testingTick(now: started.addingTimeInterval(10))
        #expect(c.phase == .warning(secondsLeft: 5, reason: .captureStalled))

        // The device came back mid-countdown — e.g. AirPods finished switching.
        c.testingConsume(smoothedDb: -25, now: started.addingTimeInterval(11))
        c.testingTick(now: started.addingTimeInterval(12))

        #expect(c.phase == .watching)
        #expect(stopped == nil)
    }

    @Test("audible level resets the silence window")
    func audibleLevelResetsSilenceWindow() {
        let started = Date(timeIntervalSince1970: 2_000)
        let c = controller()
        c.testingBegin(startedAt: started)

        c.testingConsume(
            smoothedDb: -30,
            now: started.addingTimeInterval(8)
        )

        c.testingTick(now: started.addingTimeInterval(17))
        #expect(c.phase == .watching)

        c.testingTick(now: started.addingTimeInterval(18))
        #expect(c.phase == .warning(secondsLeft: 5, reason: .silence))
    }

    @Test("keep recording dismisses warning and restarts the silence timer")
    func keepRecordingResetsWarning() {
        let started = Date(timeIntervalSince1970: 3_000)
        let c = controller()
        c.testingBegin(startedAt: started)

        c.testingTick(now: started.addingTimeInterval(10))
        #expect(c.phase == .warning(secondsLeft: 5, reason: .silence))

        c.testingKeepRecording(at: started.addingTimeInterval(12))
        #expect(c.phase == .watching)

        c.testingTick(now: started.addingTimeInterval(21))
        #expect(c.phase == .watching)

        c.testingTick(now: started.addingTimeInterval(22))
        #expect(c.phase == .warning(secondsLeft: 5, reason: .silence))
    }

    @Test("hard cap takes precedence over silence and reports hardCap")
    func hardCapPrecedence() {
        let started = Date(timeIntervalSince1970: 4_000)
        let c = controller(
            silenceThresholdSeconds: 3,
            hardCapEnabled: true,
            hardCapSeconds: 6,
            warningSeconds: 5
        )
        var stopped: AutoStopController.StopReason?
        c.onAutoStop = { stopped = $0 }
        c.testingBegin(startedAt: started)

        c.testingTick(now: started.addingTimeInterval(6))
        #expect(c.phase == .warning(secondsLeft: 5, reason: .hardCap))

        c.testingTick(now: started.addingTimeInterval(12))
        #expect(stopped == .hardCap)
    }

    @Test("stopNow preserves the current warning reason")
    func stopNowPreservesReason() {
        let started = Date(timeIntervalSince1970: 5_000)
        let c = controller(
            silenceEnabled: false,
            hardCapEnabled: true,
            hardCapSeconds: 6
        )
        var stopped: AutoStopController.StopReason?
        c.onAutoStop = { stopped = $0 }
        c.testingBegin(startedAt: started)
        c.testingTick(now: started.addingTimeInterval(6))

        c.stopNow()

        #expect(stopped == .hardCap)
        #expect(c.phase == .watching)
    }

    @Test("amplitudeHistory has fixed capacity of 96 once filled")
    func amplitudeHistoryFixedCapacity() async throws {
        let c = AutoStopController()
        var clock = Date()
        for _ in 0..<200 {
            c.testingConsume(
                smoothedDb: -20,
                micDb: -20,
                systemDb: -.infinity,
                now: clock
            )
            clock = clock.addingTimeInterval(0.05)  // step past the amplitudeInterval to push a bar
        }
        #expect(c.amplitudeHistory.count == 96)
    }

    @Test("amplitudeHistory is pre-filled to capacity at start")
    func amplitudeHistoryPrefilled() async throws {
        let c = AutoStopController()
        #expect(c.amplitudeHistory.count == 96)
        #expect(c.amplitudeHistory.allSatisfy { $0 == 0 })
    }
}
