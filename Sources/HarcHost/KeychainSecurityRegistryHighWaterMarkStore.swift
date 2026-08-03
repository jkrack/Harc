import HarcIdentity

/// Production adapter from the host security journal's narrow high-water seam
/// to the tuple-bound Keychain authority record. Every read and transition
/// revalidates the complete host tuple before authorization state can advance.
public struct KeychainSecurityRegistryHighWaterMarkStore:
    SecurityRegistryHighWaterMarkStore,
    Sendable
{
    private let cryptographicStateStore: any HostCryptographicStateStore
    private let tuple: HostCryptographicStateTuple

    public init(
        cryptographicStateStore: any HostCryptographicStateStore,
        tuple: HostCryptographicStateTuple
    ) {
        self.cryptographicStateStore = cryptographicStateStore
        self.tuple = tuple
    }

    public init(
        cryptographicStateStore: any HostCryptographicStateStore,
        metadata: HarcHostMetadata
    ) {
        self.init(
            cryptographicStateStore: cryptographicStateStore,
            tuple: HostCryptographicStateTuple(
                libraryID: metadata.libraryID,
                hostAuthorityID: metadata.hostAuthorityID,
                hostStateID: metadata.hostStateID
            )
        )
    }

    public func loadRegistryRevision() async throws -> UInt64 {
        // Serving startup uses this read while both HostDB journals are still
        // in their preflight-only phase. `load` is intentionally forbidden
        // here because resolving the protected record may create/delete a TLS
        // key or clear a crash journal before transport preflight succeeds.
        let inspection = try await cryptographicStateStore.inspect(
            requiredTuple: tuple
        )
        return inspection.securityRegistryRevision
    }

    public func advanceRegistryRevision(
        from expectedRevision: UInt64,
        to newRevision: UInt64
    ) async throws {
        _ = try await cryptographicStateStore.advanceSecurityRegistryRevision(
            for: tuple,
            from: expectedRevision,
            to: newRevision
        )
    }
}
