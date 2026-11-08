#if canImport(Network)
import Foundation
import HarcDomain
import HarcHost
import HarcStore

/// Owns post-listener publication recovery. Discovery reads only journal
/// metadata; the recovery closure must enforce resource admission and the full
/// existing publication proof before touching audio. Integrity failures are
/// retained for this process lifetime rather than retried every minute.
package actor HarcHostPublicationRecoveryScheduler {
    package static let retryInterval: TimeInterval = 60
    private static let maximumMetadataRetries = 2

    private let discover: @Sendable () async throws -> [UploadID]
    private let recover: @Sendable (UploadID) async throws -> Void
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var pending: Set<UploadID>
    private var eligibleAt: [UploadID: Date] = [:]
    private var metadataRetryCounts: [UploadID: Int] = [:]
    private var failed: Set<UploadID> = []
    private var recoveryTask: Task<Void, Never>?
    private var delayTask: Task<Void, Never>?
    private var wakeRequested = false
    private var started = false
    private var stopped = false
    private var discoveryFailed = false
    private var lastReport = HostCanonicalRecoveryReport(
        attemptedUploadCount: 0, recoveredReceiptCount: 0, failedUploadIDs: []
    )

    package init(
        initialUploadIDs: [UploadID],
        discover: @escaping @Sendable () async throws -> [UploadID],
        recover: @escaping @Sendable (UploadID) async throws -> Void,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        pending = Set(initialUploadIDs)
        self.discover = discover
        self.recover = recover
        self.now = now
        self.sleep = sleep
    }

    /// Call only after both listeners have bound. Construction is inert.
    package func start() {
        guard !started, !stopped else { return }
        started = true
        requestPass()
    }

    package func handleSystemWake() {
        guard started, !stopped else { return }
        requestPass()
    }

    /// Stops future work and joins the one in-flight recovery operation.
    package func stop() async {
        stopped = true
        wakeRequested = false
        let delay = delayTask
        delayTask = nil
        delay?.cancel()
        let recovery = recoveryTask
        recovery?.cancel()
        await recovery?.value
        await delay?.value
        recoveryTask = nil
    }

    package func status() -> HarcHostPublicationRecoveryStatus {
        HarcHostPublicationRecoveryStatus(
            isRunning: started && !stopped,
            isRecovering: recoveryTask != nil,
            pendingUploadIDs: pending.sorted(),
            failedUploadIDs: failed.sorted(),
            discoveryFailed: discoveryFailed,
            lastReport: lastReport
        )
    }

    /// Joins the current pass, not the retry timer. Useful for deterministic
    /// lifecycle tests and administrative inspection without forcing a retry.
    package func waitForCurrentPass() async {
        while let task = recoveryTask { await task.value }
    }

    private func requestPass() {
        delayTask?.cancel()
        delayTask = nil
        guard recoveryTask == nil else {
            wakeRequested = true
            return
        }
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            await self.runPass()
        }
    }

    private func runPass() async {
        var attempted = 0
        var recovered = 0
        var passFailures: [UploadID] = []
        defer {
            lastReport = HostCanonicalRecoveryReport(
                attemptedUploadCount: attempted,
                recoveredReceiptCount: recovered,
                failedUploadIDs: passFailures,
                deferredUploadIDs: pending.sorted()
            )
            recoveryTask = nil
            if !stopped, !Task.isCancelled {
                if wakeRequested {
                    wakeRequested = false
                    requestPass()
                } else {
                    scheduleNextPass()
                }
            }
        }

        do {
            let discovered = try await discover()
            try Task.checkCancellation()
            // The current journal plan wins over a prior snapshot: another
            // request may already have durably handed an upload to processing.
            pending = Set(discovered)
            eligibleAt = eligibleAt.filter { pending.contains($0.key) }
            metadataRetryCounts = metadataRetryCounts.filter { pending.contains($0.key) }
            discoveryFailed = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            // Keep the initial/previous plan available even if discovery fails.
            discoveryFailed = true
        }
        pending.subtract(failed)

        // Snapshot the entire metadata plan once. A deferred earlier entry
        // cannot starve later entries, and wakes cannot create a parallel pass.
        for uploadID in pending.sorted() {
            guard !stopped, !Task.isCancelled else { return }
            if let deadline = eligibleAt[uploadID], deadline > now() { continue }
            attempted += 1
            do {
                try await recover(uploadID)
                try Task.checkCancellation()
                pending.remove(uploadID)
                eligibleAt.removeValue(forKey: uploadID)
                metadataRetryCounts.removeValue(forKey: uploadID)
                recovered += 1
            } catch is CancellationError {
                return
            } catch is HostCanonicalResourceDeferred {
                guard !Task.isCancelled else { return }
                eligibleAt[uploadID] = now().addingTimeInterval(Self.retryInterval)
            } catch HarcHostError.canonicalPublicationAlreadyInProgress(_) {
                guard !Task.isCancelled else { return }
                // An authenticated incoming request may own the same saga.
                // Contention is not a changed binding or an integrity failure.
                eligibleAt[uploadID] = now().addingTimeInterval(Self.retryInterval)
            } catch let error as StoreError where error == .canonicalArtifactIdentityMismatch {
                guard !Task.isCancelled else { return }
                // The exact StoreError signals a descriptor/path metadata race.
                // Never refresh inside this catch: the next admitted pass must
                // restart the entire signed-evidence/content proof. HarcHostError
                // stable-field, hash and signature failures remain terminal.
                let retries = metadataRetryCounts[uploadID] ?? 0
                if retries < Self.maximumMetadataRetries {
                    metadataRetryCounts[uploadID] = retries + 1
                    eligibleAt[uploadID] = now().addingTimeInterval(Self.retryInterval)
                } else {
                    pending.remove(uploadID)
                    eligibleAt.removeValue(forKey: uploadID)
                    failed.insert(uploadID)
                    passFailures.append(uploadID)
                }
            } catch {
                guard !Task.isCancelled else { return }
                pending.remove(uploadID)
                eligibleAt.removeValue(forKey: uploadID)
                failed.insert(uploadID)
                passFailures.append(uploadID)
            }
        }
    }

    private func scheduleNextPass() {
        let sleep = self.sleep
        // No strong scheduler/runtime reference is retained during the timer.
        delayTask = Task { [weak self] in
            do { try await sleep(.seconds(Self.retryInterval)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.timerFired()
        }
    }

    private func timerFired() {
        delayTask = nil
        guard started, !stopped else { return }
        requestPass()
    }
}

public struct HarcHostPublicationRecoveryStatus: Equatable, Sendable {
    public let isRunning: Bool
    public let isRecovering: Bool
    public let pendingUploadIDs: [UploadID]
    public let failedUploadIDs: [UploadID]
    public let discoveryFailed: Bool
    public let lastReport: HostCanonicalRecoveryReport
}
#endif
