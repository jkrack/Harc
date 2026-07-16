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

    @Test("stops pinging once the active window since last dictation elapses")
    func activeWindowElapses() async throws {
        let pings = Counter()
        // Deterministic clock: pretend the last activity was 10 minutes ago
        // against a 1-minute window — the loop must idle, never ping.
        nonisolated(unsafe) var fakeNow = Date()
        let controller = DictationKeepWarmController(
            interval: 0.02,
            activeWindow: 60,
            isDaemonRunning: { true },
            ping: { await pings.bump() },
            now: { fakeNow }
        )
        controller.setEnabled(true)
        fakeNow = fakeNow.addingTimeInterval(10 * 60)
        #expect(!controller.withinActiveWindow)
        try await Task.sleep(for: .milliseconds(120))
        #expect(pings.count == 0)

        // A new dictation re-opens the window and pinging resumes.
        controller.noteActivity()
        #expect(controller.withinActiveWindow)
        let deadline = ContinuousClock.now + .seconds(5)
        while pings.count < 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.stop()
        #expect(pings.count >= 1)
    }

    @Test("nil active window never expires")
    func unboundedWindow() {
        nonisolated(unsafe) var fakeNow = Date()
        let controller = DictationKeepWarmController(
            interval: 60,
            activeWindow: nil,
            isDaemonRunning: { true },
            ping: {},
            now: { fakeNow }
        )
        fakeNow = fakeNow.addingTimeInterval(365 * 24 * 3600)
        #expect(controller.withinActiveWindow)
    }
}
