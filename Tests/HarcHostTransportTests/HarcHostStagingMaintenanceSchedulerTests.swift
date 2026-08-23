#if canImport(Network)
import Foundation
import Testing
@testable import HarcHostTransport

@Suite("Host staging maintenance scheduler")
struct HarcHostStagingMaintenanceSchedulerTests {
    @Test("a successful pass records progress and reaped uploads")
    func successfulPass() async {
        let scheduler = HarcHostStagingMaintenanceScheduler(
            reap: { 3 },
            log: { _ in }
        )
        let attemptedAt = Date(timeIntervalSince1970: 123)

        await scheduler.runNow(at: attemptedAt)

        let status = await scheduler.status()
        #expect(status.lastAttemptAt == attemptedAt)
        #expect(status.lastSuccessAt == attemptedAt)
        #expect(status.lastErrorDescription == nil)
        #expect(status.totalReapedCount == 3)
    }

    @Test("a failed pass stays nonfatal and the next pass self-heals")
    func failedPassRetries() async {
        let reaper = RecoveringMaintenanceReaper()
        let scheduler = HarcHostStagingMaintenanceScheduler(
            reap: { try await reaper.reap() },
            log: { _ in }
        )

        await scheduler.runNow(at: Date(timeIntervalSince1970: 100))
        let failed = await scheduler.status()
        #expect(failed.lastSuccessAt == nil)
        #expect(
            failed.lastErrorDescription
                == String(reflecting: MaintenanceTestError.self)
        )

        await scheduler.runNow(at: Date(timeIntervalSince1970: 200))
        let recovered = await scheduler.status()
        #expect(recovered.lastSuccessAt == Date(timeIntervalSince1970: 200))
        #expect(recovered.lastErrorDescription == nil)
        #expect(recovered.totalReapedCount == 1)
    }

    @Test("start is idempotent and shutdown cancels the periodic loop")
    func lifecycle() async {
        let sleeper = BlockingMaintenanceSleep()
        let reaper = CountingMaintenanceReaper()
        let scheduler = HarcHostStagingMaintenanceScheduler(
            reap: { await reaper.reap() },
            sleep: { duration in try await sleeper.sleep(for: duration) },
            log: { _ in }
        )

        await scheduler.start()
        await scheduler.start()
        await reaper.waitForCount(1)
        #expect((await scheduler.status()).isRunning)

        await scheduler.stop()
        #expect(!(await scheduler.status()).isRunning)
        #expect(await reaper.count() == 1)
    }
}

private enum MaintenanceTestError: Error {
    case unavailable
}

private actor RecoveringMaintenanceReaper {
    private var attempts = 0

    func reap() throws -> Int {
        attempts += 1
        if attempts == 1 { throw MaintenanceTestError.unavailable }
        return 1
    }
}

private actor CountingMaintenanceReaper {
    private var value = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func reap() -> Int {
        value += 1
        let ready = waiters
        waiters.removeAll()
        ready.forEach { $0.resume() }
        return 0
    }

    func count() -> Int { value }

    func waitForCount(_ target: Int) async {
        while value < target {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}

private actor BlockingMaintenanceSleep {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .seconds(3_600))
    }
}

#endif
