import Foundation
import HarcIdentity

public enum HarcGRPCServedIdentityBindingError:
    Error, Equatable, Sendable
{
    case wrongGeneration
    case notBound
    case alreadyBound
    case invalidated
    case invalidTLSSPKISHA256
}

/// One-shot proof that a bootstrap service generation is using the TLS
/// identity that its listener actually bound. Production code cannot bind this
/// reference from caller-supplied digest bytes: the package-only binder accepts
/// the concrete identity released by `HostTransportListenerMaterial` at the
/// listener bind transition.
public final class HarcGRPCServedIdentityBinding: @unchecked Sendable {
    private enum State {
        case unbound
        case bound(Data)
        case invalidated
    }

    public let generationID: UUID

    private let lock = NSLock()
    private var state: State = .unbound

    public init(generationID: UUID) {
        self.generationID = generationID
    }

    /// Listener integration hook. Call this inside the existing
    /// `HostTransportListenerMaterial.bindServerIdentity` transform, using the
    /// generation ID carried by the same listener lease.
    package func bindFromListenerIdentity(
        _ identity: HostTLSServerIdentity,
        generationID: UUID
    ) throws {
        try bind(
            tlsSPKISHA256: identity.certificate.tlsSPKISHA256,
            generationID: generationID
        )
    }

    /// Runtime teardown hook. Once invalidated, a reference cannot be revived
    /// or reused for a replacement transport generation.
    package func invalidate(generationID: UUID) throws {
        guard generationID == self.generationID else {
            throw HarcGRPCServedIdentityBindingError.wrongGeneration
        }
        lock.lock()
        defer { lock.unlock() }
        state = .invalidated
    }

    func requireTLSSPKISHA256(generationID: UUID) throws -> Data {
        guard generationID == self.generationID else {
            throw HarcGRPCServedIdentityBindingError.wrongGeneration
        }
        return try lock.withLock {
            switch state {
            case .unbound:
                throw HarcGRPCServedIdentityBindingError.notBound
            case .bound(let digest):
                return digest
            case .invalidated:
                throw HarcGRPCServedIdentityBindingError.invalidated
            }
        }
    }

    /// Internal-only seam for adapter tests. Production composition has no
    /// digest-based binding API.
    init(
        generationID: UUID,
        testTLSSPKISHA256: Data
    ) throws {
        self.generationID = generationID
        try bind(
            tlsSPKISHA256: testTLSSPKISHA256,
            generationID: generationID
        )
    }

    func bindTestTLSSPKISHA256(
        _ tlsSPKISHA256: Data,
        generationID: UUID
    ) throws {
        try bind(
            tlsSPKISHA256: tlsSPKISHA256,
            generationID: generationID
        )
    }

    private func bind(
        tlsSPKISHA256: Data,
        generationID: UUID
    ) throws {
        guard generationID == self.generationID else {
            throw HarcGRPCServedIdentityBindingError.wrongGeneration
        }
        guard tlsSPKISHA256.count == 32 else {
            throw HarcGRPCServedIdentityBindingError.invalidTLSSPKISHA256
        }
        try lock.withLock {
            switch state {
            case .unbound:
                state = .bound(tlsSPKISHA256)
            case .bound:
                throw HarcGRPCServedIdentityBindingError.alreadyBound
            case .invalidated:
                throw HarcGRPCServedIdentityBindingError.invalidated
            }
        }
    }
}
