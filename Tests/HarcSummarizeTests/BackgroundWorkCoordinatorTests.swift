import Testing
import Foundation
@testable import HarcSummarize

@Suite("BackgroundWorkCoordinator")
struct BackgroundWorkCoordinatorTests {

    /// Actor-based overlap counter — if two `performOne` bodies ever run
    /// concurrently, `peak` will climb above 1.
    actor OverlapCounter {
        private(set) var active = 0
        private(set) var peak = 0
        func enter() { active += 1; peak = max(peak, active) }
        func leave() { active -= 1 }
    }

    @Test("two concurrent performOne calls run serially (peak concurrency == 1)")
    func serializesConcurrentCallers() async throws {
        let coord = BackgroundWorkCoordinator()
        let counter = OverlapCounter()

        async let first: Void = coord.performOne {
            await counter.enter()
            try await Task.sleep(nanoseconds: 40_000_000)   // 40 ms
            await counter.leave()
        }
        async let second: Void = coord.performOne {
            await counter.enter()
            try await Task.sleep(nanoseconds: 40_000_000)
            await counter.leave()
        }
        _ = try await (first, second)

        let peak = await counter.peak
        #expect(peak == 1)
    }

    @Test("performOne rethrows the operation's error and releases the slot")
    func rethrowsAndReleases() async throws {
        struct Boom: Error {}
        let coord = BackgroundWorkCoordinator()

        await #expect(throws: Boom.self) {
            try await coord.performOne { throw Boom() }
        }
        // Slot must be free — a second call should complete without hanging.
        let result: Int = try await coord.performOne { 42 }
        #expect(result == 42)
    }

    @Test("performOne returns the operation's value")
    func passesReturnValueThrough() async throws {
        let coord = BackgroundWorkCoordinator()
        let value: String = try await coord.performOne { "hello" }
        #expect(value == "hello")
    }
}
