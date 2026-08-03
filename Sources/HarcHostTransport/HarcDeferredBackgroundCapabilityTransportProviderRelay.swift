#if canImport(Network)
import Foundation
import HarcHost

package enum HarcDeferredBackgroundCapabilityTransportProviderRelayError:
    Error, Equatable, Sendable
{
    case providerAlreadyInstalled
}

/// Breaks resident composition's construction cycle without exposing the
/// runtime or its writer lease. Requests arriving during the narrow startup
/// window suspend until the one concrete resident provider is installed.
package actor HarcDeferredBackgroundCapabilityTransportProviderRelay:
    HostBackgroundCapabilityTransportSnapshotProviding
{
    private typealias Provider = HarcResidentBackgroundCapabilityTransportProvider
    private typealias ProviderContinuation = CheckedContinuation<Provider, any Error>

    private var provider: Provider?
    private var waiters: [UUID: ProviderContinuation] = [:]
    private var pendingCountWaiters: [(
        minimumCount: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []

    package init() {}

    /// Installs the sole resident provider. Every later call, including an
    /// exact replay of the first value, fails instead of replacing authority.
    package func install(
        _ provider: HarcResidentBackgroundCapabilityTransportProvider
    ) throws {
        guard self.provider == nil else {
            throw HarcDeferredBackgroundCapabilityTransportProviderRelayError
                .providerAlreadyInstalled
        }
        self.provider = provider

        let pending = Array(waiters.values)
        waiters.removeAll(keepingCapacity: false)
        for continuation in pending {
            continuation.resume(returning: provider)
        }
    }

    package func reserveBackgroundCapabilityTransport(
        forHTTPPath httpPath: String,
        capabilityExpiresAt: Date
    ) async throws -> HostBackgroundCapabilityTransportSnapshot {
        let provider = try await installedProvider()
        try Task.checkCancellation()
        return try await provider.reserveBackgroundCapabilityTransport(
            forHTTPPath: httpPath,
            capabilityExpiresAt: capabilityExpiresAt
        )
    }

    private func installedProvider() async throws -> Provider {
        try Task.checkCancellation()
        if let provider {
            return provider
        }

        let waiterID = UUID()
        let installed: Provider = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: ProviderContinuation) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let provider {
                    // Installation can win while this actor method is
                    // suspended entering the cancellation handler.
                    continuation.resume(returning: provider)
                } else {
                    waiters[waiterID] = continuation
                    resumeSatisfiedPendingCountWaiters()
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
        try Task.checkCancellation()
        return installed
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let continuation = waiters.removeValue(forKey: waiterID) else {
            return
        }
        continuation.resume(throwing: CancellationError())
    }

    // Internal deterministic observation seams for focused concurrency tests.
    // They expose only aggregate queue depth, never provider or runtime state.
    func waitUntilPendingRequestCountForTesting(_ minimumCount: Int) async {
        guard waiters.count < minimumCount else { return }
        await withCheckedContinuation { continuation in
            pendingCountWaiters.append((minimumCount, continuation))
        }
    }

    func pendingRequestCountForTesting() -> Int {
        waiters.count
    }

    private func resumeSatisfiedPendingCountWaiters() {
        var remaining: [(
            minimumCount: Int,
            continuation: CheckedContinuation<Void, Never>
        )] = []
        for waiter in pendingCountWaiters {
            if waiters.count >= waiter.minimumCount {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        pendingCountWaiters = remaining
    }
}
#endif
