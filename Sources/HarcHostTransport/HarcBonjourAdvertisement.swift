#if canImport(Network)
import Foundation
import HarcProtocol
import Network

package enum HarcBonjourAdvertisementError: Error, Equatable, Sendable {
    case generationMismatch
    case advertisementNotArmed
    case generationWithdrawn
    case listenerRegistrationFailed
}

package enum HarcBonjourAdvertisementState: Equatable, Sendable {
    case idle
    case armed
    case attached
    case registered
    case withdrawn
    case failed
}

package protocol HarcBonjourListenerAdvertisementBoundary: Sendable {
    func arm(forGenerationID id: UUID) async throws
    func attach(to listener: NWListener, generationID id: UUID) async throws
    func waitUntilRegistered(generationID id: UUID) async throws
    func failRegistration(generationID id: UUID) async
    func withdraw(generationID id: UUID) async
}

/// Owns DNS-SD registration for exactly one listener generation. The
/// `NWListener.Service` is installed on the same concrete listener consumed by
/// gRPC's TransportServices bootstrap; there is no second listener, NetService,
/// or custom multicast publisher.
package actor HarcBonjourListenerAdvertisement:
    HarcBonjourListenerAdvertisementBoundary
{
    private enum State {
        case idle
        case armed
        case attached(NWListener)
        case registered(NWListener)
        case withdrawn
        case failed
    }

    private let generationID: UUID
    private let hints: HarcBonjourServiceHintsV1
    private var state: State = .idle
    private var registrationWaiters: [CheckedContinuation<Void, any Error>] = []

    package init(
        generationID: UUID,
        hints: HarcBonjourServiceHintsV1
    ) {
        self.generationID = generationID
        self.hints = hints
    }

    package func arm(forGenerationID id: UUID) throws {
        try requireGeneration(id)
        switch state {
        case .idle:
            state = .armed
        case .armed, .attached, .registered:
            return
        case .withdrawn:
            throw HarcBonjourAdvertisementError.generationWithdrawn
        case .failed:
            throw HarcBonjourAdvertisementError.listenerRegistrationFailed
        }
    }

    package func attach(
        to listener: NWListener,
        generationID id: UUID
    ) throws {
        try requireGeneration(id)
        switch state {
        case .armed:
            break
        case .attached(let existing), .registered(let existing):
            guard existing === listener else {
                throw HarcBonjourAdvertisementError.listenerRegistrationFailed
            }
            return
        case .idle:
            throw HarcBonjourAdvertisementError.advertisementNotArmed
        case .withdrawn:
            listener.service = nil
            throw HarcBonjourAdvertisementError.generationWithdrawn
        case .failed:
            listener.service = nil
            throw HarcBonjourAdvertisementError.listenerRegistrationFailed
        }

        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            Task { await self?.registrationChanged(change, generationID: id) }
        }
        listener.service = NWListener.Service(
            name: hints.displayName,
            type: HarcBonjourServiceHintsV1.serviceType,
            domain: nil,
            txtRecord: NWTXTRecord(hints.txtRecord)
        )
        state = .attached(listener)
    }

    package func waitUntilRegistered(generationID id: UUID) async throws {
        try requireGeneration(id)
        switch state {
        case .registered:
            return
        case .attached, .armed:
            try await withCheckedThrowingContinuation { continuation in
                registrationWaiters.append(continuation)
            }
        case .idle:
            throw HarcBonjourAdvertisementError.advertisementNotArmed
        case .withdrawn:
            throw HarcBonjourAdvertisementError.generationWithdrawn
        case .failed:
            throw HarcBonjourAdvertisementError.listenerRegistrationFailed
        }
    }

    package func failRegistration(generationID id: UUID) {
        guard id == generationID else { return }
        let listener = attachedListener
        state = .failed
        listener?.service = nil
        listener?.serviceRegistrationUpdateHandler = nil
        resumeRegistrationWaiters(
            throwing: HarcBonjourAdvertisementError.listenerRegistrationFailed
        )
    }

    /// Tombstoning is the first mutation and this method contains no suspension
    /// before clearing the service. A late `arm` or `attach` therefore fails
    /// closed even when activation was suspended elsewhere.
    package func withdraw(generationID id: UUID) {
        guard id == generationID else { return }
        let listener = attachedListener
        state = .withdrawn
        listener?.service = nil
        listener?.serviceRegistrationUpdateHandler = nil
        resumeRegistrationWaiters(
            throwing: HarcBonjourAdvertisementError.generationWithdrawn
        )
    }

    package var stateSnapshot: HarcBonjourAdvertisementState {
        switch state {
        case .idle: .idle
        case .armed: .armed
        case .attached: .attached
        case .registered: .registered
        case .withdrawn: .withdrawn
        case .failed: .failed
        }
    }

    /// Stable seam for registration tests; production reaches the same path
    /// only through `serviceRegistrationUpdateHandler`.
    package func reportRegistrationAddedForTesting(generationID id: UUID) {
        registrationAdded(generationID: id)
    }

    private var attachedListener: NWListener? {
        switch state {
        case .attached(let listener), .registered(let listener): listener
        case .idle, .armed, .withdrawn, .failed: nil
        }
    }

    private func registrationChanged(
        _ change: NWListener.ServiceRegistrationChange,
        generationID id: UUID
    ) {
        switch change {
        case .add:
            registrationAdded(generationID: id)
        case .remove:
            if case .registered(let listener) = state {
                state = .attached(listener)
            }
        @unknown default:
            failRegistration(generationID: id)
        }
    }

    private func registrationAdded(generationID id: UUID) {
        guard id == generationID,
              case .attached(let listener) = state else { return }
        state = .registered(listener)
        for waiter in registrationWaiters { waiter.resume() }
        registrationWaiters.removeAll()
    }

    private func resumeRegistrationWaiters(throwing error: any Error) {
        for waiter in registrationWaiters {
            waiter.resume(throwing: error)
        }
        registrationWaiters.removeAll()
    }

    private func requireGeneration(_ id: UUID) throws {
        guard id == generationID else {
            throw HarcBonjourAdvertisementError.generationMismatch
        }
    }
}

package protocol HarcBonjourGenerationPublisherBoundary: Sendable {
    /// Arms the factory before either listener starts. The service itself is
    /// attached later, inside the factory, to the real gRPC `NWListener`.
    func prepareAdvertisement(
        forGenerationID id: UUID,
        listenerFactory: HarcGRPCNWListenerFactory
    ) async throws

    func withdrawAdvertisement(forGenerationID id: UUID) async
}

/// Generation-scoped publisher used by the resident driver. It remembers the
/// exact factory so withdrawal can clear the exact listener advertisement.
package actor HarcNWListenerBonjourGenerationPublisher:
    HarcBonjourGenerationPublisherBoundary
{
    private var factories: [UUID: HarcGRPCNWListenerFactory] = [:]
    private var tombstones: Set<UUID> = []

    package init() {}

    package func prepareAdvertisement(
        forGenerationID id: UUID,
        listenerFactory: HarcGRPCNWListenerFactory
    ) async throws {
        guard !tombstones.contains(id) else {
            throw HarcBonjourAdvertisementError.generationWithdrawn
        }
        factories[id] = listenerFactory
        try await listenerFactory.armBonjourAdvertisement(generationID: id)
        if tombstones.contains(id) {
            await listenerFactory.withdrawBonjourAdvertisement(generationID: id)
            throw HarcBonjourAdvertisementError.generationWithdrawn
        }
    }

    package func withdrawAdvertisement(forGenerationID id: UUID) async {
        tombstones.insert(id)
        guard let factory = factories.removeValue(forKey: id) else { return }
        await factory.withdrawBonjourAdvertisement(generationID: id)
    }
}
#endif
