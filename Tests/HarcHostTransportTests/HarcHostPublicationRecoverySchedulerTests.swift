#if canImport(Network)
import Foundation
import HarcDomain
import HarcHost
import HarcStore
import Testing
@testable import HarcHostTransport

@Suite("Post-listener Host publication recovery")
struct HarcHostPublicationRecoverySchedulerTests {
    @Test("construction is inert and start is idempotent")
    func constructionDoesNotRecoverAudio() async {
        let id = recoveryID(1)
        let probe = PublicationRecoveryProbe(ids: [id])
        let scheduler = makeRecoveryScheduler(probe)
        #expect(await probe.calls == [])
        #expect(!(await scheduler.status()).isRunning)

        await scheduler.start()
        await scheduler.start()
        await scheduler.waitForCurrentPass()
        #expect(await probe.calls == [id])
        #expect((await scheduler.status()).lastReport.recoveredReceiptCount == 1)
        await scheduler.stop()
    }

    @Test("resource deferral does not starve later work or retry before its deadline")
    func resourceDeferralHasBoundedRetry() async {
        let blocked = recoveryID(1)
        let later = recoveryID(2)
        let clock = PublicationRecoveryClock()
        let probe = PublicationRecoveryProbe(ids: [blocked, later], deferred: [blocked])
        let scheduler = makeRecoveryScheduler(probe, clock: clock)
        await scheduler.start()
        await scheduler.waitForCurrentPass()
        let first = await scheduler.status()
        #expect(await probe.calls == [blocked, later])
        #expect(first.pendingUploadIDs == [blocked])
        #expect(first.failedUploadIDs.isEmpty)
        #expect(first.lastReport.deferredUploadIDs == [blocked])
        #expect(first.lastReport.attemptedUploadCount == 2)
        #expect(first.lastReport.recoveredReceiptCount == 1)

        await probe.allow(blocked)
        clock.advance(59)
        await scheduler.handleSystemWake()
        await scheduler.waitForCurrentPass()
        #expect(await probe.calls == [blocked, later])
        clock.advance(1)
        await scheduler.handleSystemWake()
        await scheduler.waitForCurrentPass()
        #expect(await probe.calls == [blocked, later, blocked])
        #expect((await scheduler.status()).pendingUploadIDs.isEmpty)
        await scheduler.stop()
    }

    @Test("current journal metadata drops an already-handed-off startup entry")
    func refreshedPlanDropsStaleEntry() async {
        let alreadyHandedOff = recoveryID(1)
        let probe = PublicationRecoveryProbe(ids: [])
        let scheduler = makeRecoveryScheduler(probe, initial: [alreadyHandedOff])
        await scheduler.start()
        await scheduler.waitForCurrentPass()
        #expect(await probe.calls.isEmpty)
        #expect((await scheduler.status()).pendingUploadIDs.isEmpty)
        await scheduler.stop()
    }

    @Test("an in-flight incoming publication defers without becoming a permanent failure")
    func publicationContentionIsRetryable() async {
        let busy = recoveryID(1)
        let later = recoveryID(2)
        let clock = PublicationRecoveryClock()
        let probe = PublicationRecoveryProbe(ids: [busy, later], busy: [busy])
        let scheduler = makeRecoveryScheduler(probe, clock: clock)
        await scheduler.start()
        await scheduler.waitForCurrentPass()
        #expect(await probe.calls == [busy, later])
        #expect((await scheduler.status()).failedUploadIDs.isEmpty)
        #expect((await scheduler.status()).pendingUploadIDs == [busy])
        await probe.allow(busy)
        clock.advance(60)
        await scheduler.handleSystemWake()
        await scheduler.waitForCurrentPass()
        #expect(await probe.calls == [busy, later, busy])
        #expect((await scheduler.status()).pendingUploadIDs.isEmpty)
        await scheduler.stop()
    }

    @Test("integrity failures are retained until a new scheduler is created")
    func integrityFailureDoesNotLoop() async {
        let blocked = recoveryID(1)
        let later = recoveryID(2)
        let probe = PublicationRecoveryProbe(ids: [blocked, later], failed: [blocked])
        let scheduler = makeRecoveryScheduler(probe)
        await scheduler.start()
        await scheduler.waitForCurrentPass()
        #expect((await scheduler.status()).failedUploadIDs == [blocked])
        await probe.allow(blocked)
        await scheduler.handleSystemWake()
        await scheduler.waitForCurrentPass()
        #expect(await probe.calls == [blocked, later])
        await scheduler.stop()

        let reopened = makeRecoveryScheduler(probe)
        await reopened.start()
        await reopened.waitForCurrentPass()
        #expect(await probe.calls == [blocked, later, blocked])
        #expect((await reopened.status()).failedUploadIDs.isEmpty)
        await reopened.stop()
    }

    @Test("a metadata race retries the entire recovery only after its deadline")
    func metadataRaceRetriesAfterDelay() async {
        let id = recoveryID(1)
        let clock = PublicationRecoveryClock()
        let probe = PublicationRecoveryProbe(ids: [id], metadataFailures: [id: 1])
        let scheduler = makeRecoveryScheduler(probe, clock: clock)
        await scheduler.start()
        await scheduler.waitForCurrentPass()
        #expect(await probe.calls == [id])
        #expect((await scheduler.status()).failedUploadIDs.isEmpty)
        #expect((await scheduler.status()).pendingUploadIDs == [id])
        clock.advance(59)
        await scheduler.handleSystemWake()
        await scheduler.waitForCurrentPass()
        #expect(await probe.calls == [id])
        clock.advance(1)
        await scheduler.handleSystemWake()
        await scheduler.waitForCurrentPass()
        #expect(await probe.calls == [id, id])
        #expect((await scheduler.status()).lastReport.recoveredReceiptCount == 1)
        #expect((await scheduler.status()).pendingUploadIDs.isEmpty)
        await scheduler.stop()
    }

    @Test("metadata retry budget survives wakes and resource deferral, then exhausts")
    func repeatedMetadataRacesExhaustBudget() async {
        let id = recoveryID(1)
        let clock = PublicationRecoveryClock()
        let probe = PublicationRecoveryProbe(ids: [id], metadataFailures: [id: 3])
        let scheduler = makeRecoveryScheduler(probe, clock: clock)
        await scheduler.start()
        await scheduler.waitForCurrentPass()
        #expect(await probe.calls.count == 1)
        await scheduler.handleSystemWake()
        await scheduler.waitForCurrentPass()
        #expect(await probe.calls.count == 1)

        await probe.deferResources(id)
        clock.advance(60)
        await scheduler.handleSystemWake()
        await scheduler.waitForCurrentPass()
        #expect(await probe.calls.count == 2)
        #expect((await scheduler.status()).failedUploadIDs.isEmpty)
        await probe.allow(id)
        clock.advance(60)
        await scheduler.handleSystemWake()
        await scheduler.waitForCurrentPass()
        #expect(await probe.calls.count == 3)
        #expect((await scheduler.status()).failedUploadIDs.isEmpty)
        clock.advance(60)
        await scheduler.handleSystemWake()
        await scheduler.waitForCurrentPass()
        #expect(await probe.calls.count == 4)
        #expect((await scheduler.status()).failedUploadIDs == [id])
        #expect((await scheduler.status()).pendingUploadIDs.isEmpty)
        clock.advance(60)
        await scheduler.handleSystemWake()
        await scheduler.waitForCurrentPass()
        #expect(await probe.calls.count == 4)
        await scheduler.stop()
    }

    @Test("metadata retry budget clears after success or disappearance", arguments: [false, true])
    func metadataBudgetClearsWhenWorkLeavesPlan(_ succeeds: Bool) async {
        let id = recoveryID(1)
        let clock = PublicationRecoveryClock()
        let probe = PublicationRecoveryProbe(ids: [id], metadataFailures: [id: 1])
        let scheduler = makeRecoveryScheduler(probe, clock: clock)
        await scheduler.start()
        await scheduler.waitForCurrentPass()
        if succeeds { clock.advance(60) }
        else { await probe.hide(id) }
        await scheduler.handleSystemWake()
        await scheduler.waitForCurrentPass()
        #expect((await scheduler.status()).pendingUploadIDs.isEmpty)

        await probe.restore(id, metadataFailures: 2)
        for attempt in 0 ..< 3 {
            if attempt > 0 { clock.advance(60) }
            await scheduler.handleSystemWake()
            await scheduler.waitForCurrentPass()
        }
        #expect((await scheduler.status()).failedUploadIDs.isEmpty)
        #expect((await scheduler.status()).pendingUploadIDs.isEmpty)
        #expect((await scheduler.status()).lastReport.recoveredReceiptCount == 1)
        await scheduler.stop()
    }

    @Test("overlapping wake requests coalesce and recovery remains serial")
    func wakeCoalescesDuringRecovery() async {
        let first = recoveryID(1)
        let second = recoveryID(2)
        let probe = PublicationRecoveryProbe(ids: [first, second], held: first)
        let scheduler = makeRecoveryScheduler(probe)
        await scheduler.start()
        await probe.waitForCalls(1)
        await scheduler.handleSystemWake()
        await scheduler.handleSystemWake()
        await scheduler.handleSystemWake()
        await probe.release()
        await scheduler.waitForCurrentPass()
        #expect(await probe.calls == [first, second])
        #expect(await probe.maximumConcurrentRecoveries == 1)
        #expect(await probe.discoveries == 2)
        await scheduler.stop()
    }

    @Test("shutdown cancels and joins in-flight work without declaring integrity failure")
    func shutdownJoinsRecovery() async {
        let first = recoveryID(1)
        let second = recoveryID(2)
        let probe = PublicationRecoveryProbe(ids: [first, second], cancellationBlocked: first)
        let scheduler = makeRecoveryScheduler(probe)
        await scheduler.start()
        await probe.waitForCalls(1)
        await scheduler.stop()
        await scheduler.handleSystemWake()
        let status = await scheduler.status()
        #expect(!status.isRunning)
        #expect(!status.isRecovering)
        #expect(status.failedUploadIDs.isEmpty)
        #expect(status.pendingUploadIDs == [first, second])
        #expect(await probe.observedCancellation)
        #expect(await probe.activeRecoveries == 0)
        #expect(await probe.calls == [first])
    }

    @Test("metadata discovery failure preserves the initial plan and is observable")
    func discoveryFailurePreservesPlan() async {
        let id = recoveryID(1)
        let probe = PublicationRecoveryProbe(ids: [id], discoveryFails: true)
        let scheduler = makeRecoveryScheduler(probe, initial: [id])
        await scheduler.start()
        await scheduler.waitForCurrentPass()
        #expect(await probe.calls == [id])
        #expect((await scheduler.status()).discoveryFailed)
        await probe.allowDiscovery()
        await scheduler.handleSystemWake()
        await scheduler.waitForCurrentPass()
        #expect(!(await scheduler.status()).discoveryFailed)
        await scheduler.stop()
    }

    @Test("the owned timer retries deferred work and stops cleanly")
    func timerRetriesDeferredWork() async {
        let id = recoveryID(1)
        let clock = PublicationRecoveryClock()
        let sleeper = PublicationRecoverySleeper()
        let probe = PublicationRecoveryProbe(ids: [id], deferred: [id])
        let scheduler = HarcHostPublicationRecoveryScheduler(
            initialUploadIDs: [], discover: { try await probe.discover() },
            recover: { try await probe.recover($0) }, now: { clock.now() },
            sleep: { try await sleeper.sleep($0) }
        )
        await scheduler.start()
        await scheduler.waitForCurrentPass()
        await sleeper.waitForSleeps(1)
        #expect(await sleeper.durations == [.seconds(60)])
        await probe.allow(id)
        clock.advance(60)
        await sleeper.fire()
        await probe.waitForCalls(2)
        await scheduler.waitForCurrentPass()
        #expect(await probe.calls == [id, id])
        #expect((await scheduler.status()).pendingUploadIDs.isEmpty)
        await scheduler.stop()
    }
}

private func recoveryID(_ suffix: Int) -> UploadID {
    UploadID(UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", suffix))")!)
}

private func makeRecoveryScheduler(
    _ probe: PublicationRecoveryProbe,
    clock: PublicationRecoveryClock = PublicationRecoveryClock(),
    initial: [UploadID] = []
) -> HarcHostPublicationRecoveryScheduler {
    HarcHostPublicationRecoveryScheduler(
        initialUploadIDs: initial,
        discover: { try await probe.discover() },
        recover: { try await probe.recover($0) },
        now: { clock.now() },
        sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
    )
}

private final class PublicationRecoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 100)

    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(seconds) }
    }
}

private enum PublicationRecoveryTestError: Error {
    case discovery
}

private actor PublicationRecoveryProbe {
    private var ids: [UploadID]
    private var deferred: Set<UploadID>
    private var failed: Set<UploadID>
    private var busy: Set<UploadID>
    private var metadataFailures: [UploadID: Int]
    private let held: UploadID?
    private let cancellationBlocked: UploadID?
    private var discoveryFails: Bool
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var calls: [UploadID] = []
    private(set) var discoveries = 0
    private(set) var activeRecoveries = 0
    private(set) var maximumConcurrentRecoveries = 0
    private(set) var observedCancellation = false

    init(ids: [UploadID], deferred: Set<UploadID> = [], failed: Set<UploadID> = [], busy: Set<UploadID> = [],
         metadataFailures: [UploadID: Int] = [:],
         held: UploadID? = nil, cancellationBlocked: UploadID? = nil,
         discoveryFails: Bool = false) {
        self.ids = ids
        self.deferred = deferred
        self.failed = failed
        self.busy = busy
        self.metadataFailures = metadataFailures
        self.held = held
        self.cancellationBlocked = cancellationBlocked
        self.discoveryFails = discoveryFails
    }

    func discover() throws -> [UploadID] {
        discoveries += 1
        if discoveryFails { throw PublicationRecoveryTestError.discovery }
        return ids
    }

    func recover(_ id: UploadID) async throws {
        calls.append(id)
        activeRecoveries += 1
        maximumConcurrentRecoveries = max(maximumConcurrentRecoveries, activeRecoveries)
        defer { activeRecoveries -= 1 }
        let ready = callWaiters.filter { $0.0 <= calls.count }
        callWaiters.removeAll { $0.0 <= calls.count }
        ready.forEach { $0.1.resume() }
        if id == held {
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        if id == cancellationBlocked {
            do { try await Task.sleep(for: .seconds(3_600)) }
            catch { observedCancellation = true; throw error }
        }
        if deferred.contains(id) { throw HostCanonicalResourceDeferred.audioNotResident }
        if busy.contains(id) { throw HarcHostError.canonicalPublicationAlreadyInProgress(id) }
        if failed.contains(id) { throw HarcHostError.canonicalArtifactIdentityMismatch }
        if let remaining = metadataFailures[id], remaining > 0 {
            metadataFailures[id] = remaining - 1
            throw StoreError.canonicalArtifactIdentityMismatch
        }
        ids.removeAll { $0 == id }
    }

    func allow(_ id: UploadID) { deferred.remove(id); failed.remove(id); busy.remove(id) }
    func deferResources(_ id: UploadID) { deferred.insert(id) }
    func hide(_ id: UploadID) { ids.removeAll { $0 == id } }
    func restore(_ id: UploadID, metadataFailures: Int) {
        if !ids.contains(id) { ids.append(id) }
        self.metadataFailures[id] = metadataFailures
    }
    func allowDiscovery() { discoveryFails = false }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
    func waitForCalls(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { callWaiters.append((count, $0)) }
    }
}

private actor PublicationRecoverySleeper {
    private var continuations: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var durations: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                continuations[id] = continuation
                durations.append(duration)
                let ready = waiters.filter { $0.0 <= durations.count }
                waiters.removeAll { $0.0 <= durations.count }
                ready.forEach { $0.1.resume() }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
    func fire() {
        let ready = Array(continuations.values)
        continuations.removeAll()
        ready.forEach { $0.resume() }
    }
    func waitForSleeps(_ count: Int) async {
        if durations.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}
#endif
