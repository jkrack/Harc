import Foundation
import HarcIdentity

package enum HostTransportListenerRole: String, CaseIterable, Hashable, Sendable {
    case grpcControl
    case backgroundUpload
}

package enum HostTransportGenerationError: Error, Equatable, Sendable {
    case staleLease
    case wrongRole
    case leaseAlreadyConsumed
    case leaseAlreadyBound
    case generationAlreadyActive
    case generationNotPrepared
    case incompleteActivation
    case authorityRuntimeAlreadyActive
}

/// Material crosses into HarcHostTransport only at the listener's bind point.
/// It is never retained as a reusable readiness snapshot.
package struct HostTransportListenerMaterial: Sendable {
    private let lifecycle: HostTransportLifecycle
    private let leaseID: UUID
    private let generationID: UUID
    private let role: HostTransportListenerRole

    /// Performs the single lifecycle-accounted bind transition. The identity
    /// is scoped to this nonescaping transform and is not exposed as reusable
    /// material on the value crossing into the transport target.
    package func bindServerIdentity<T: Sendable>(
        for expectedRole: HostTransportListenerRole,
        _ transform: @Sendable (HostTLSServerIdentity) throws -> T
    ) async throws -> T {
        guard role == expectedRole else {
            throw HostTransportGenerationError.wrongRole
        }
        let identity = try await lifecycle.bindConsumedListenerMaterial(
            leaseID: leaseID,
            generationID: generationID,
            role: role
        )
        return try transform(identity)
    }

    package init(
        lifecycle: HostTransportLifecycle,
        leaseID: UUID,
        generationID: UUID,
        role: HostTransportListenerRole
    ) {
        self.lifecycle = lifecycle
        self.leaseID = leaseID
        self.generationID = generationID
        self.role = role
    }
}

/// A role-bound, one-shot capability. Copying the reference does not duplicate
/// authority: consumption is checked and recorded by the resident lifecycle.
package final class HostTransportListenerLease: @unchecked Sendable {
    private let lifecycle: HostTransportLifecycle
    package let generationID: UUID
    package let role: HostTransportListenerRole
    package let leaseID: UUID

    package init(
        lifecycle: HostTransportLifecycle,
        generationID: UUID,
        role: HostTransportListenerRole,
        leaseID: UUID
    ) {
        self.lifecycle = lifecycle
        self.generationID = generationID
        self.role = role
        self.leaseID = leaseID
    }

    package func consume(
        for expectedRole: HostTransportListenerRole
    ) async throws -> HostTransportListenerMaterial {
        guard role == expectedRole else {
            throw HostTransportGenerationError.wrongRole
        }
        return try await lifecycle.consumeListenerLease(
            leaseID: leaseID,
            generationID: generationID,
            role: role
        )
    }
}

/// The two listeners form one exposure unit. A generation boundary receives
/// both one-shot leases and must either start both or expose neither.
package struct HostTransportGenerationTerminationReporter: Sendable {
    package let generationID: UUID

    private let report: @Sendable () async -> Void

    package init(
        generationID: UUID,
        report: @escaping @Sendable () async -> Void
    ) {
        self.generationID = generationID
        self.report = report
    }

    /// Reports failure of this exact generation. The callback itself carries
    /// the generation identity, so a transport cannot relabel a terminal event
    /// with another generation's identifier.
    package func reportUnexpectedTermination() async {
        await report()
    }
}

package struct HostTransportServingGeneration: Sendable {
    package let generationID: UUID
    package let transportEpoch: UInt64
    package let transportSetObjectID: Data
    package let renewAt: Date
    package let hardStopAt: Date
    package let grpcControl: HostTransportListenerLease
    package let backgroundUpload: HostTransportListenerLease
    package let terminationReporter: HostTransportGenerationTerminationReporter
}

package struct HostTransportGenerationStatus: Equatable, Sendable {
    package let generationID: UUID
    package let transportEpoch: UInt64
    package let renewAt: Date
    package let hardStopAt: Date
}

/// Process-wide ownership closes the second-runtime path that a per-actor gate
/// cannot cover. The production runtime retains the returned claim until stop.
package actor HostTransportAuthorityRuntimeRegistry {
    package static let shared = HostTransportAuthorityRuntimeRegistry()

    private var claims: [HostCryptographicStateTuple: UUID] = [:]

    package func claim(
        _ tuple: HostCryptographicStateTuple
    ) throws -> HostTransportAuthorityRuntimeClaim {
        guard claims[tuple] == nil else {
            throw HostTransportGenerationError.authorityRuntimeAlreadyActive
        }
        let id = UUID()
        claims[tuple] = id
        return HostTransportAuthorityRuntimeClaim(
            tuple: tuple,
            id: id,
            registry: self
        )
    }

    fileprivate func release(tuple: HostCryptographicStateTuple, id: UUID) {
        guard claims[tuple] == id else { return }
        claims.removeValue(forKey: tuple)
    }
}

package final class HostTransportAuthorityRuntimeClaim: @unchecked Sendable {
    package let tuple: HostCryptographicStateTuple
    private let id: UUID
    private let registry: HostTransportAuthorityRuntimeRegistry

    fileprivate init(
        tuple: HostCryptographicStateTuple,
        id: UUID,
        registry: HostTransportAuthorityRuntimeRegistry
    ) {
        self.tuple = tuple
        self.id = id
        self.registry = registry
    }

    package func release() async {
        await registry.release(tuple: tuple, id: id)
    }
}
