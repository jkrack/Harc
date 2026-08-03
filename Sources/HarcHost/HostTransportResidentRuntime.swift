import Foundation
import HarcIdentity

/// The only production owner of a host authority's lifecycle, generation
/// boundary, and renewal task. Public callers receive operations on this actor,
/// never the underlying lifecycle or a reusable TLS identity snapshot.
package actor HostTransportResidentRuntime {
    package let store: HarcHostStore

    private let lifecycle: HostTransportLifecycle
    private let scheduler: HostTransportRenewalScheduler
    private let authorityClaim: HostTransportAuthorityRuntimeClaim
    private var stopped = false

    package static func start(
        store: HarcHostStore,
        cryptographicStateStore: any HostCryptographicStateStore,
        transportSetProtocol: any HostTransportSetProtocolBoundary,
        generationBoundary: any HostTransportGenerationBoundary,
        canonicalTuple: HostCryptographicStateTuple,
        now: @escaping @Sendable () -> Date = Date.init
    ) async throws -> HostTransportResidentRuntime {
        let storeTuple = HostCryptographicStateTuple(
            libraryID: store.expectedMetadata.libraryID,
            hostAuthorityID: store.expectedMetadata.hostAuthorityID,
            hostStateID: store.expectedMetadata.hostStateID
        )
        guard canonicalTuple == storeTuple else {
            throw HarcHostError.metadataMismatch
        }
        let claim = try await HostTransportAuthorityRuntimeRegistry.shared.claim(
            canonicalTuple
        )
        let lifecycle = HostTransportLifecycle(
            store: store,
            cryptographicStateStore: cryptographicStateStore,
            transportSetProtocol: transportSetProtocol,
            generationBoundary: generationBoundary,
            now: now
        )
        do {
            if try await store.requiresDeferredServingBootstrap() {
                try await store.withServingRecoverySecurityExclusion {
                    let inspection = try await cryptographicStateStore.inspect(
                        requiredTuple: canonicalTuple
                    )
                    // Both plans are proven read-only before either HostDB or
                    // protected-record recovery is permitted to advance.
                    let securityPlan = try await store.preflightSecurityRegistry(
                        protectedRevision: inspection.securityRegistryRevision
                    )
                    let transportPlan = try await lifecycle
                        .preflightDeferredServingTransport(inspection: inspection)
                    try await store.reconcileSecurityRegistry(using: securityPlan)
                    try await lifecycle.reconcileDeferredServingTransport(
                        using: transportPlan,
                        expectedSecurityRegistryRevision:
                            securityPlan.pendingRevision ?? securityPlan.databaseRevision
                    )
                    try await store.completeDeferredServingBootstrap()
                }
            }
            _ = try await lifecycle.prepareForServing()
            let scheduler = HostTransportRenewalScheduler(
                lifecycle: lifecycle,
                now: now
            )
            await lifecycle.installGenerationUnavailableHandler {
                [weak scheduler] in
                await scheduler?.generationBecameUnavailable()
            }
            let runtime = HostTransportResidentRuntime(
                store: store,
                lifecycle: lifecycle,
                scheduler: scheduler,
                authorityClaim: claim
            )
            await scheduler.start()
            return runtime
        } catch {
            await claim.release()
            throw error
        }
    }

    private init(
        store: HarcHostStore,
        lifecycle: HostTransportLifecycle,
        scheduler: HostTransportRenewalScheduler,
        authorityClaim: HostTransportAuthorityRuntimeClaim
    ) {
        self.store = store
        self.lifecycle = lifecycle
        self.scheduler = scheduler
        self.authorityClaim = authorityClaim
    }

    package func beginPlannedRotation() async throws {
        _ = try await lifecycle.beginPlannedRotation()
    }

    package func completePlannedRotation() async throws {
        _ = try await lifecycle.completePlannedRotation()
    }

    package func performEmergencyRotation(
        compromisedTLSSPKISHA256: Data? = nil
    ) async throws {
        _ = try await lifecycle.performEmergencyRotation(
            compromisedTLSSPKISHA256: compromisedTLSSPKISHA256
        )
    }

    package func reserveTransportForCapability(
        expiringAt expiry: Date
    ) async throws -> HostCapabilityTransportReservation {
        try await lifecycle.reserveTransportForCapability(expiringAt: expiry)
    }

    package func generationStatus() async -> HostTransportGenerationStatus? {
        await lifecycle.generationStatus()
    }

    package func handleSystemWake() async {
        await scheduler.handleWake()
    }

    package func shutdown() async {
        guard !stopped else { return }
        stopped = true
        await scheduler.stop()
        await lifecycle.shutdownServingGeneration()
        await authorityClaim.release()
    }
}

private actor HostTransportRenewalScheduler {
    private let lifecycle: HostTransportLifecycle
    private let now: @Sendable () -> Date
    private var task: Task<Void, Never>?
    private(set) var lastErrorDescription: String?

    init(
        lifecycle: HostTransportLifecycle,
        now: @escaping @Sendable () -> Date
    ) {
        self.lifecycle = lifecycle
        self.now = now
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() async {
        let stopping = task
        task = nil
        stopping?.cancel()
        await stopping?.value
    }

    /// Interrupts a potentially days-long renewal sleep. The replacement loop
    /// follows the ordinary nil-generation retry path, including its bounded
    /// five-minute backoff on repeated bind failures.
    func generationBecameUnavailable() {
        guard task != nil else { return }
        task?.cancel()
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func handleWake() async {
        if await lifecycle.enforceRenewalHardStopIfNeeded() { return }
        guard let status = await lifecycle.generationStatus() else {
            do {
                _ = try await lifecycle.prepareForServing()
                lastErrorDescription = nil
            } catch {
                lastErrorDescription = String(describing: error)
            }
            return
        }
        guard now() >= status.renewAt else { return }
        do {
            _ = try await lifecycle.renewServingGenerationIfNeeded()
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = String(describing: error)
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            guard let status = await lifecycle.generationStatus() else {
                do {
                    _ = try await lifecycle.prepareForServing()
                    lastErrorDescription = nil
                } catch {
                    lastErrorDescription = String(describing: error)
                    if !(await sleep(seconds: HostTransportLifecycle.renewalRetryInterval)) {
                        return
                    }
                }
                continue
            }

            let delay = status.renewAt.timeIntervalSince(now())
            if delay > 0, !(await sleep(seconds: delay)) { return }
            if Task.isCancelled { return }

            do {
                _ = try await lifecycle.renewServingGenerationIfNeeded()
                lastErrorDescription = nil
            } catch {
                lastErrorDescription = String(describing: error)
                if await lifecycle.enforceRenewalHardStopIfNeeded() { continue }
                let remaining = status.hardStopAt.timeIntervalSince(now())
                let retry = min(
                    HostTransportLifecycle.renewalRetryInterval,
                    max(0, remaining)
                )
                if !(await sleep(seconds: retry)) { return }
            }
        }
    }

    private func sleep(seconds: TimeInterval) async -> Bool {
        guard seconds > 0 else { return !Task.isCancelled }
        let bounded = min(seconds, Double(UInt64.max) / 1_000_000_000)
        do {
            try await Task.sleep(
                nanoseconds: UInt64((bounded * 1_000_000_000).rounded(.up))
            )
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}
