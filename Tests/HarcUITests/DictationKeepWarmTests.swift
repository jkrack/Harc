import Testing
import Foundation
@testable import HarcUI

/// Async signal that resolves once a counter reaches a target.
@MainActor
private final class Counter {
    private(set) var count = 0
    func bump() { count += 1 }
}

@Suite("DictationKeepWarmController")
@MainActor
struct DictationKeepWarmTests {
    @Test("pings while enabled and the daemon is running")
    func pingsWhenRunning() async throws {
        let pings = Counter()
        let controller = DictationKeepWarmController(
            interval: 0.02,
            isDaemonRunning: { true },
            ping: { await pings.bump() }
        )
        controller.setEnabled(true)
        #expect(controller.isRunning)
        // Poll instead of a fixed sleep — wall-clock timing is unreliable
        // under full parallel suite load.
        let deadline = ContinuousClock.now + .seconds(5)
        while pings.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.stop()
        #expect(pings.count >= 2)
    }

    @Test("never pings when the daemon isn't running — and never launches it")
    func skipsWhenNotRunning() async throws {
        let pings = Counter()
        let probes = Counter()
        let controller = DictationKeepWarmController(
            interval: 0.02,
            isDaemonRunning: { await probes.bump(); return false },
            ping: { await pings.bump() }
        )
        controller.setEnabled(true)
        // Wait for at least two probe cycles so "no ping" is meaningful.
        let deadline = ContinuousClock.now + .seconds(5)
        while probes.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.stop()
        #expect(probes.count >= 1)   // it checked
        #expect(pings.count == 0)    // but never pinged (nor launched)
    }

    @Test("setEnabled(false) stops the loop; re-enable restarts it")
    func stopByPref() async throws {
        let pings = Counter()
        let controller = DictationKeepWarmController(
            interval: 0.02,
            isDaemonRunning: { true },
            ping: { await pings.bump() }
        )
        controller.setEnabled(true)
        let deadline = ContinuousClock.now + .seconds(5)
        while pings.count < 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.setEnabled(false)
        #expect(!controller.isRunning)
        let after = pings.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(pings.count == after)

        controller.setEnabled(true)
        #expect(controller.isRunning)
        controller.stop()
    }

    @Test("setEnabled(true) twice doesn't stack loops")
    func idempotentStart() {
        let controller = DictationKeepWarmController(
            interval: 60,
            isDaemonRunning: { true },
            ping: {}
        )
        controller.setEnabled(true)
        controller.setEnabled(true)
        #expect(controller.isRunning)
        controller.stop()
        #expect(!controller.isRunning)
    }
}
