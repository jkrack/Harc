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
        warningSeconds: Int = 5
    ) -> AutoStopController {
        AutoStopController(config: AutoStopController.Config(
            silenceEnabled: silenceEnabled,
            silenceThresholdSeconds: silenceThresholdSeconds,
            silenceDbCeiling: -50,
            hardCapEnabled: hardCapEnabled,
            hardCapSeconds: hardCapSeconds,
            warningSeconds: warningSeconds
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
