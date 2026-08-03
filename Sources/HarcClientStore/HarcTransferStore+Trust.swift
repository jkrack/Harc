import Foundation
import GRDB
import HarcDomain
import HarcTransfer

public struct AdoptedTrustTuple: Equatable, Hashable, Sendable {
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID

    public init(libraryID: LibraryID, hostAuthorityID: HostAuthorityID) {
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
    }

    fileprivate init(hostTrust: RecordingHostTrustBinding) {
        self.init(
            libraryID: hostTrust.libraryID,
            hostAuthorityID: hostTrust.hostAuthorityID
        )
    }
}

/// Read-only stored projection of validator-owned transport-set evidence.
/// Persistence APIs accept `ValidatedTransportSetEvidence`, whose package-only
/// initializer is the actual trust boundary.
public struct VerifiedTransportSetSlot: Equatable, Sendable {
    public let tuple: AdoptedTrustTuple
    public let epoch: UInt64
    public let exactSignedBytes: Data

    fileprivate init(
        tuple: AdoptedTrustTuple,
        epoch: UInt64,
        exactSignedBytes: Data
    ) throws {
        guard epoch > 0 else {
            throw ClientStoreError.integerOutOfRange(field: "transportEpoch", value: epoch)
        }
        _ = try ClientStoreCoding.sqliteInteger(epoch, field: "transportEpoch")
        guard !exactSignedBytes.isEmpty else {
            throw ClientStoreError.emptyOpaqueBytes(field: "exactTransportSet")
        }
        self.tuple = tuple
        self.epoch = epoch
        self.exactSignedBytes = exactSignedBytes
    }

    fileprivate init(evidence: ValidatedTransportSetEvidence) throws {
        try self.init(
            tuple: AdoptedTrustTuple(hostTrust: evidence.hostTrust),
            epoch: evidence.epoch,
            exactSignedBytes: evidence.exactSignedBytes
        )
    }
}

public typealias StoredGrantStatus = ValidatedDeviceGrantStatus

/// Read-only stored projection of validator-owned device-grant evidence.
public struct VerifiedDeviceGrantSlot: Equatable, Sendable {
    public let tuple: AdoptedTrustTuple
    public let protocolVersion: ClientGrantProtocolVersion
    public let grantID: GrantID
    public let deviceID: DeviceID
    public let devicePublicKeyX963: Data
    public let scopes: [ClientAuthorizationScope]
    public let registryEpoch: UInt64
    public let issuedAt: Date
    public let expiresAt: Date?
    public let minimumCompatibleProtocolMinor: UInt16
    public let maximumCompatibleProtocolMinor: UInt16
    public let status: StoredGrantStatus
    public let exactSignedBytes: Data

    fileprivate init(
        tuple: AdoptedTrustTuple,
        protocolVersion: ClientGrantProtocolVersion,
        grantID: GrantID,
        deviceID: DeviceID,
        devicePublicKeyX963: Data,
        scopes: [ClientAuthorizationScope],
        registryEpoch: UInt64,
        issuedAt: Date,
        expiresAt: Date?,
        minimumCompatibleProtocolMinor: UInt16,
        maximumCompatibleProtocolMinor: UInt16,
        status: StoredGrantStatus,
        exactSignedBytes: Data
    ) throws {
        guard registryEpoch > 0 else {
            throw ClientStoreError.integerOutOfRange(field: "grantEpoch", value: registryEpoch)
        }
        _ = try ClientStoreCoding.sqliteInteger(registryEpoch, field: "grantEpoch")
        guard !exactSignedBytes.isEmpty else {
            throw ClientStoreError.emptyOpaqueBytes(field: "exactGrant")
        }
        do {
            _ = try ValidatedClientGrantClaimsProjection(
                protocolVersion: protocolVersion,
                libraryID: tuple.libraryID,
                hostAuthorityID: tuple.hostAuthorityID,
                grantID: grantID,
                deviceID: deviceID,
                devicePublicKeyX963: devicePublicKeyX963,
                scopes: scopes,
                registryEpoch: registryEpoch,
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                minimumCompatibleProtocolMinor: minimumCompatibleProtocolMinor,
                maximumCompatibleProtocolMinor: maximumCompatibleProtocolMinor
            )
        } catch {
            throw ClientStoreError.corruptStoredValue(field: "grantClaims")
        }
        self.tuple = tuple
        self.protocolVersion = protocolVersion
        self.grantID = grantID
        self.deviceID = deviceID
        self.devicePublicKeyX963 = devicePublicKeyX963
        self.scopes = scopes
        self.registryEpoch = registryEpoch
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.minimumCompatibleProtocolMinor = minimumCompatibleProtocolMinor
        self.maximumCompatibleProtocolMinor = maximumCompatibleProtocolMinor
        self.status = status
        self.exactSignedBytes = exactSignedBytes
    }

    fileprivate init(evidence: ValidatedDeviceGrantEvidence) throws {
        let tuple = AdoptedTrustTuple(hostTrust: evidence.hostTrust)
        let claims = evidence.clientClaims
        guard claims.libraryID == tuple.libraryID,
              claims.hostAuthorityID == tuple.hostAuthorityID else {
            throw ClientStoreError.trustEvidenceBindingMismatch(field: "grant.hostTrust")
        }
        try self.init(
            tuple: tuple,
            protocolVersion: claims.protocolVersion,
            grantID: claims.grantID,
            deviceID: claims.deviceID,
            devicePublicKeyX963: claims.devicePublicKeyX963,
            scopes: claims.scopes,
            registryEpoch: claims.registryEpoch,
            issuedAt: claims.issuedAt,
            expiresAt: claims.expiresAt,
            minimumCompatibleProtocolMinor: claims.minimumCompatibleProtocolMinor,
            maximumCompatibleProtocolMinor: claims.maximumCompatibleProtocolMinor,
            status: evidence.status,
            exactSignedBytes: evidence.exactSignedBytes
        )
    }
}

private struct VerifiedAuthorityReplacement: Equatable, Sendable {
    let replacingHostTrust: RecordingHostTrustBinding
    let replacement: VerifiedAdoption

    init(
        replacingHostTrust: RecordingHostTrustBinding,
        replacement: VerifiedAdoption
    ) {
        self.replacingHostTrust = replacingHostTrust
        self.replacement = replacement
    }

    init(evidence: ValidatedClientAuthorityReplacementEvidence) throws {
        let replacement = try VerifiedAdoption(evidence: evidence.replacementAdoption)
        guard evidence.replacingHostTrust.libraryID == replacement.tuple.libraryID,
              evidence.replacingHostTrust.hostAuthorityID
                != replacement.tuple.hostAuthorityID else {
            throw ClientStoreError.trustEvidenceBindingMismatch(
                field: "authorityReplacement"
            )
        }
        replacingHostTrust = evidence.replacingHostTrust
        self.replacement = replacement
    }

    var request: ClientAuthorityReplacementRequest {
        ClientAuthorityReplacementRequest(
            libraryID: replacingHostTrust.libraryID,
            replacingHostAuthorityID: replacingHostTrust.hostAuthorityID,
            replacementHostAuthorityID: replacement.tuple.hostAuthorityID
        )
    }
}

private struct VerifiedAdoption: Equatable, Sendable {
    public let tuple: AdoptedTrustTuple
    public let authorityPublicKeyX963: Data
    public let transportSet: VerifiedTransportSetSlot
    public let grant: VerifiedDeviceGrantSlot
    public let adoptedAt: Date

    init(evidence: ValidatedClientAdoptionEvidence) throws {
        let tuple = AdoptedTrustTuple(hostTrust: evidence.hostTrust)
        let transportSet = try VerifiedTransportSetSlot(evidence: evidence.transportSet)
        let grant = try VerifiedDeviceGrantSlot(evidence: evidence.grant)
        guard transportSet.tuple == tuple else {
            throw ClientStoreError.trustEvidenceBindingMismatch(field: "transportSet.tuple")
        }
        guard grant.tuple == tuple else {
            throw ClientStoreError.trustEvidenceBindingMismatch(field: "grant.tuple")
        }
        guard evidence.adoptedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ClientStoreError.corruptStoredValue(field: "adoptedAt")
        }
        self.tuple = tuple
        authorityPublicKeyX963 = evidence.hostTrust.hostAuthorityPublicKeyX963
        self.transportSet = transportSet
        self.grant = grant
        adoptedAt = evidence.adoptedAt
    }
}

public struct ActiveAdoptionSnapshot: Equatable, Sendable {
    public let adoptionID: UUID
    public let tuple: AdoptedTrustTuple
    public let authorityPublicKeyX963: Data
    public let transportSet: VerifiedTransportSetSlot
    public let grant: VerifiedDeviceGrantSlot
    public let adoptedAt: Date

    /// Structural registry status only. Call the store's scope-specific
    /// authorization API to enforce expiry and the required operation scope.
    public var hasActiveGrantStatus: Bool { grant.status == .active }
}

public struct HistoricalAdoptionSnapshot: Equatable, Sendable {
    public let adoptionID: UUID
    public let tuple: AdoptedTrustTuple
    public let transportEpochAtRead: UInt64
    public let grantEpoch: UInt64
    public let adoptedAt: Date
    public let endedAt: Date

    public var isAuthorizing: Bool { false }
}

public enum EpochPersistenceDisposition: Equatable, Sendable {
    case inserted
    case advanced(previous: UInt64, current: UInt64)
    case exactReplay(epoch: UInt64)
}

public final class HarcTransferStore: @unchecked Sendable {
    let database: ClientStoreDatabase
    public let installationDeviceID: DeviceID
    private let faultInjector: any ClientStoreFaultInjecting
    private let authorityReplacementAuthorizationBoundary:
        any ClientAuthorityReplacementAuthorizationBoundary
    let now: @Sendable () -> Date

    public convenience init(
        rootDirectory: URL,
        installationDeviceID: DeviceID,
        storageAttributes: any ClientStoreStorageAttributeApplying = FoundationClientStoreStorageAttributes(),
        authorityReplacementAuthorizationBoundary:
            any ClientAuthorityReplacementAuthorizationBoundary =
                RejectingClientAuthorityReplacementAuthorizationBoundary(),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        let locations = try ClientStoreLocations(rootDirectory: rootDirectory)
        try self.init(
            databaseURL: locations.transferDatabase,
            installationDeviceID: installationDeviceID,
            storageAttributes: storageAttributes,
            authorityReplacementAuthorizationBoundary:
                authorityReplacementAuthorizationBoundary,
            now: now
        )
    }

    public init(
        databaseURL: URL,
        installationDeviceID: DeviceID,
        storageAttributes: any ClientStoreStorageAttributeApplying = FoundationClientStoreStorageAttributes(),
        faultInjector: any ClientStoreFaultInjecting = NoClientStoreFaults(),
        authorityReplacementAuthorizationBoundary:
            any ClientAuthorityReplacementAuthorizationBoundary =
                RejectingClientAuthorityReplacementAuthorizationBoundary(),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard databaseURL.lastPathComponent == ClientStoreDatabaseKind.transfer.fileName else {
            throw ClientStoreError.unexpectedDatabaseFileName(
                expected: ClientStoreDatabaseKind.transfer.fileName,
                actual: databaseURL.lastPathComponent
            )
        }
        database = try ClientStoreDatabase(
            databaseURL: databaseURL,
            policy: .transfer,
            attributes: storageAttributes,
            migrator: ClientStoreMigrators.transfer()
        )
        self.installationDeviceID = installationDeviceID
        self.faultInjector = faultInjector
        self.authorityReplacementAuthorizationBoundary =
            authorityReplacementAuthorizationBoundary
        self.now = now
    }

    public var databaseURL: URL { database.databaseURL }

    /// Atomically retires the prior active adoption and installs one complete,
    /// validator-owned tuple, transport high-water value, and exact grant.
    /// Ordinary adoption never revives a revoked registry identity.
    @discardableResult
    public func adopt(
        _ evidence: ValidatedClientAdoptionEvidence
    ) throws -> ActiveAdoptionSnapshot {
        let adoption = try VerifiedAdoption(evidence: evidence)
        guard adoption.grant.status == .active else {
            throw ClientStoreError.nonauthorizingGrantStatus(adoption.grant.status.rawValue)
        }
        return try installAdoption(adoption, grantTransition: .ordinary)
    }

    /// Explicit same-key re-adoption transition for a revoked installation.
    /// This is deliberately separate from ordinary registry advancement: it
    /// requires the same tuple, authority key, and DeviceID, exactly the next
    /// epoch, an active replacement, and a new GrantID. The prior adoption is
    /// retired and the replacement becomes current in the same transaction.
    @discardableResult
    public func readoptRevokedGrant(
        _ evidence: ValidatedClientAdoptionEvidence
    ) throws -> ActiveAdoptionSnapshot {
        let adoption = try VerifiedAdoption(evidence: evidence)
        return try installAdoption(adoption, grantTransition: .revokedReadoption)
    }

    /// Explicitly replaces the remembered authority for one LibraryID. The
    /// validator evidence binds the old anchor to the newly verified adoption;
    /// the injected foreground boundary then performs the exact local choice
    /// and OS-authentication prompt. The transaction rechecks that selection
    /// after authentication before it archives the old tuple and installs the
    /// replacement.
    @discardableResult
    public func replaceHostAuthority(
        _ evidence: ValidatedClientAuthorityReplacementEvidence
    ) async throws -> ActiveAdoptionSnapshot {
        let replacement = try VerifiedAuthorityReplacement(evidence: evidence)
        guard replacement.replacement.grant.status == .active else {
            throw ClientStoreError.nonauthorizingGrantStatus(
                replacement.replacement.grant.status.rawValue
            )
        }
        try database.read { db in
            try validateAuthorityReplacementSelection(replacement, in: db)
        }
        try await authorityReplacementAuthorizationBoundary
            .authorizeAuthorityReplacement(replacement.request)
        return try installAdoption(
            replacement.replacement,
            grantTransition: .authorityReplacement(
                replacingHostTrust: replacement.replacingHostTrust
            )
        )
    }

    private enum GrantTransition: Equatable {
        case ordinary
        case revokedReadoption
        case authorityReplacement(replacingHostTrust: RecordingHostTrustBinding)
    }

    private func installAdoption(
        _ adoption: VerifiedAdoption,
        grantTransition: GrantTransition
    ) throws -> ActiveAdoptionSnapshot {
        guard adoption.grant.deviceID == installationDeviceID else {
            throw ClientStoreError.grantDeviceMismatch(
                expected: installationDeviceID,
                presented: adoption.grant.deviceID
            )
        }
        return try database.write { db in
            if grantTransition == .ordinary,
               let remembered = try mostRecentlyRememberedAuthority(
                    for: adoption.tuple.libraryID,
                    in: db
               ),
               remembered != adoption.tuple.hostAuthorityID {
                throw ClientStoreError
                    .authorityReplacementRequiresExplicitAuthorization(
                        libraryID: adoption.tuple.libraryID,
                        remembered: remembered,
                        presented: adoption.tuple.hostAuthorityID
                    )
            }
            if let active = try activeAdoption(in: db) {
                switch grantTransition {
                case .ordinary:
                    break
                case .revokedReadoption:
                    break
                case .authorityReplacement(let replacingHostTrust):
                    try validateAuthorityReplacementSelection(
                        VerifiedAuthorityReplacement(
                            replacingHostTrust: replacingHostTrust,
                            replacement: adoption
                        ),
                        active: active
                    )
                }
            } else if case .authorityReplacement = grantTransition {
                throw ClientStoreError.authorityReplacementSelectionMismatch
            }

            let namespace = try namespaceRow(for: adoption.tuple, in: db)
            try validateAuthorityKey(
                adoption.authorityPublicKeyX963,
                against: namespace
            )
            let transportDisposition = try validateTransportUpdate(
                adoption.transportSet,
                tuple: adoption.tuple,
                against: namespace
            )
            let grantDisposition = try validateGrantUpdate(
                adoption.grant,
                tuple: adoption.tuple,
                transition: grantTransition,
                in: db
            )

            if grantTransition == .revokedReadoption,
               case .exactReplay = grantDisposition {
                guard case .exactReplay = transportDisposition,
                      let active = try activeAdoption(in: db),
                      active.tuple == adoption.tuple,
                      active.authorityPublicKeyX963 == adoption.authorityPublicKeyX963,
                      active.transportSet == adoption.transportSet,
                      active.grant == adoption.grant,
                      try ClientStoreCoding.milliseconds(active.adoptedAt)
                        == ClientStoreCoding.milliseconds(adoption.adoptedAt) else {
                    throw ClientStoreError.trustEvidenceBindingMismatch(
                        field: "re-adoption replay"
                    )
                }
                return active
            }

            let adoptedAtMS = try ClientStoreCoding.milliseconds(adoption.adoptedAt)
            try db.execute(
                sql: """
                    UPDATE adoption_history
                    SET ended_at_ms = ?
                    WHERE ended_at_ms IS NULL
                    """,
                arguments: [adoptedAtMS]
            )
            try faultInjector.trigger(.afterDeactivatingPriorAdoption)

            try persistNamespace(
                adoption,
                prior: namespace,
                disposition: transportDisposition,
                in: db
            )
            try faultInjector.trigger(.afterWritingTrustNamespace)
            try persistGrant(
                adoption.grant,
                tuple: adoption.tuple,
                disposition: grantDisposition,
                storedAtMS: adoptedAtMS,
                in: db
            )

            let adoptionID = UUID()
            try db.execute(
                sql: """
                    INSERT INTO adoption_history (
                        adoption_id, library_id, host_authority_id, grant_epoch,
                        adopted_at_ms, ended_at_ms
                    ) VALUES (?, ?, ?, ?, ?, NULL)
                    """,
                arguments: [
                    adoptionID.uuidString.lowercased(),
                    adoption.tuple.libraryID.description,
                    adoption.tuple.hostAuthorityID.rawBytes,
                    try ClientStoreCoding.sqliteInteger(
                        adoption.grant.registryEpoch,
                        field: "grantEpoch"
                    ),
                    adoptedAtMS,
                ]
            )

            return ActiveAdoptionSnapshot(
                adoptionID: adoptionID,
                tuple: adoption.tuple,
                authorityPublicKeyX963: adoption.authorityPublicKeyX963,
                transportSet: adoption.transportSet,
                grant: adoption.grant,
                adoptedAt: adoption.adoptedAt
            )
        }
    }

    private func mostRecentlyRememberedAuthority(
        for libraryID: LibraryID,
        in db: Database
    ) throws -> HostAuthorityID? {
        guard let bytes = try Data.fetchOne(
            db,
            sql: """
                SELECT host_authority_id
                FROM adoption_history
                WHERE library_id = ?
                ORDER BY rowid DESC
                LIMIT 1
                """,
            arguments: [libraryID.description]
        ) else { return nil }
        return try HostAuthorityID(bytes)
    }

    public func activeAdoption() throws -> ActiveAdoptionSnapshot? {
        try database.read { db in
            guard let active = try activeAdoption(in: db) else { return nil }
            guard active.grant.deviceID == installationDeviceID else {
                throw ClientStoreError.grantDeviceMismatch(
                    expected: installationDeviceID,
                    presented: active.grant.deviceID
                )
            }
            return active
        }
    }

    /// The only trust read intended for request authorization. An exact tuple
    /// mismatch, including one found in history, fails as nonauthorizing.
    public func authorizingAdoption(
        for tuple: AdoptedTrustTuple,
        requiredScope: ClientAuthorizationScope
    ) throws -> ActiveAdoptionSnapshot {
        try database.read { db in
            guard let active = try activeAdoption(in: db) else {
                throw ClientStoreError.noActiveAdoption
            }
            guard active.tuple == tuple else {
                throw ClientStoreError.inactiveTrustTuple(
                    libraryID: tuple.libraryID,
                    hostAuthorityID: tuple.hostAuthorityID
                )
            }
            try requireAuthorizingGrant(
                active.grant,
                requiredScope: requiredScope
            )
            return active
        }
    }

    public func historicalAdoptions() throws -> [HistoricalAdoptionSnapshot] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT adoption_id, library_id, host_authority_id,
                           highest_transport_epoch, grant_epoch,
                           adopted_at_ms, ended_at_ms
                    FROM adoption_history
                    JOIN trust_namespaces USING (library_id, host_authority_id)
                    WHERE ended_at_ms IS NOT NULL
                    ORDER BY adopted_at_ms, adoption_id
                    """
            )
            return try rows.map { row in
                guard
                    let adoptionID = UUID(uuidString: row["adoption_id"] as String),
                    let libraryUUID = UUID(uuidString: row["library_id"] as String),
                    let endedAtMS = row["ended_at_ms"] as Int64?
                else {
                    throw ClientStoreError.corruptStoredValue(field: "adoptionHistory")
                }
                let authorityID = try HostAuthorityID(row["host_authority_id"] as Data)
                let transportEpoch = try ClientStoreCoding.unsigned(
                    row["highest_transport_epoch"] as Int64,
                    field: "transportEpoch"
                )
                let grantEpoch = try ClientStoreCoding.unsigned(
                    row["grant_epoch"] as Int64,
                    field: "grantEpoch"
                )
                return HistoricalAdoptionSnapshot(
                    adoptionID: adoptionID,
                    tuple: AdoptedTrustTuple(
                        libraryID: LibraryID(libraryUUID),
                        hostAuthorityID: authorityID
                    ),
                    transportEpochAtRead: transportEpoch,
                    grantEpoch: grantEpoch,
                    adoptedAt: ClientStoreCoding.date(
                        milliseconds: row["adopted_at_ms"] as Int64
                    ),
                    endedAt: ClientStoreCoding.date(milliseconds: endedAtMS)
                )
            }
        }
    }

    @discardableResult
    public func persistVerifiedTransportSet(
        _ evidence: ValidatedTransportSetEvidence
    ) throws -> EpochPersistenceDisposition {
        let slot = try VerifiedTransportSetSlot(evidence: evidence)
        let tuple = slot.tuple
        return try database.write { db in
            let selected = try requireSelected(tuple, in: db)
            guard selected.authorityPublicKeyX963 == evidence.hostTrust.hostAuthorityPublicKeyX963 else {
                throw ClientStoreError.authorityKeyEquivocation
            }
            guard let namespace = try namespaceRow(for: tuple, in: db) else {
                throw ClientStoreError.missingRow(entity: "trust namespace")
            }
            let disposition = try validateTransportUpdate(
                slot,
                tuple: tuple,
                against: namespace
            )
            switch disposition {
            case .exactReplay:
                break
            case .inserted:
                // An active adoption always has a namespace.
                throw ClientStoreError.missingRow(entity: "trust namespace")
            case .advanced:
                try db.execute(
                    sql: """
                        UPDATE trust_namespaces
                        SET highest_transport_epoch = ?, exact_transport_set = ?, updated_at_ms = ?
                        WHERE library_id = ? AND host_authority_id = ?
                        """,
                    arguments: [
                        try ClientStoreCoding.sqliteInteger(slot.epoch, field: "transportEpoch"),
                        slot.exactSignedBytes,
                        try ClientStoreCoding.milliseconds(now()),
                        tuple.libraryID.description,
                        tuple.hostAuthorityID.rawBytes,
                    ]
                )
            }
            return disposition
        }
    }

    @discardableResult
    public func persistNextVerifiedGrant(
        _ evidence: ValidatedDeviceGrantEvidence
    ) throws -> EpochPersistenceDisposition {
        let grant = try VerifiedDeviceGrantSlot(evidence: evidence)
        let tuple = grant.tuple
        return try database.write { db in
            let selected = try requireSelected(tuple, in: db)
            guard selected.authorityPublicKeyX963 == evidence.hostTrust.hostAuthorityPublicKeyX963 else {
                throw ClientStoreError.authorityKeyEquivocation
            }
            guard grant.deviceID == installationDeviceID else {
                throw ClientStoreError.grantDeviceMismatch(
                    expected: installationDeviceID,
                    presented: grant.deviceID
                )
            }
            let disposition = try validateGrantUpdate(
                grant,
                tuple: tuple,
                transition: .ordinary,
                in: db
            )
            let storedAtMS = try ClientStoreCoding.milliseconds(now())
            try persistGrant(
                grant,
                tuple: tuple,
                disposition: disposition,
                storedAtMS: storedAtMS,
                in: db
            )
            if case .exactReplay = disposition {
                return disposition
            }
            try db.execute(
                sql: """
                    UPDATE adoption_history
                    SET grant_epoch = ?
                    WHERE ended_at_ms IS NULL
                      AND library_id = ? AND host_authority_id = ?
                    """,
                arguments: [
                    try ClientStoreCoding.sqliteInteger(grant.registryEpoch, field: "grantEpoch"),
                    tuple.libraryID.description,
                    tuple.hostAuthorityID.rawBytes,
                ]
            )
            return disposition
        }
    }

    public func refreshStorageAttributes() throws {
        try database.refreshStorageAttributes()
    }

    public func checkpoint() throws {
        try database.checkpoint()
    }

    private struct NamespaceRow {
        let authorityPublicKeyX963: Data
        let transportEpoch: UInt64
        let exactTransportSet: Data
    }

    private func namespaceRow(
        for tuple: AdoptedTrustTuple,
        in db: Database
    ) throws -> NamespaceRow? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT authority_public_key_x963, highest_transport_epoch, exact_transport_set
                FROM trust_namespaces
                WHERE library_id = ? AND host_authority_id = ?
                """,
            arguments: [tuple.libraryID.description, tuple.hostAuthorityID.rawBytes]
        ) else { return nil }
        return NamespaceRow(
            authorityPublicKeyX963: row["authority_public_key_x963"],
            transportEpoch: try ClientStoreCoding.unsigned(
                row["highest_transport_epoch"],
                field: "transportEpoch"
            ),
            exactTransportSet: row["exact_transport_set"]
        )
    }

    private func validateAuthorityKey(_ key: Data, against row: NamespaceRow?) throws {
        guard key.count == 65, key.first == 0x04 else {
            throw ClientStoreError.invalidAuthorityPublicKey
        }
        if let row, row.authorityPublicKeyX963 != key {
            throw ClientStoreError.authorityKeyEquivocation
        }
    }

    private func validateTransportUpdate(
        _ slot: VerifiedTransportSetSlot,
        tuple: AdoptedTrustTuple,
        against row: NamespaceRow?
    ) throws -> EpochPersistenceDisposition {
        guard slot.tuple == tuple else {
            throw ClientStoreError.trustEvidenceBindingMismatch(field: "transportSet.tuple")
        }
        guard let row else { return .inserted }
        if slot.epoch < row.transportEpoch {
            throw ClientStoreError.transportEpochRollback(
                stored: row.transportEpoch,
                presented: slot.epoch
            )
        }
        if slot.epoch == row.transportEpoch {
            guard slot.exactSignedBytes == row.exactTransportSet else {
                throw ClientStoreError.transportEpochEquivocation(epoch: slot.epoch)
            }
            return .exactReplay(epoch: slot.epoch)
        }
        return .advanced(previous: row.transportEpoch, current: slot.epoch)
    }

    private func persistNamespace(
        _ adoption: VerifiedAdoption,
        prior: NamespaceRow?,
        disposition: EpochPersistenceDisposition,
        in db: Database
    ) throws {
        let nowMS = try ClientStoreCoding.milliseconds(adoption.adoptedAt)
        switch disposition {
        case .inserted:
            try db.execute(
                sql: """
                    INSERT INTO trust_namespaces (
                        library_id, host_authority_id, authority_public_key_x963,
                        highest_transport_epoch, exact_transport_set,
                        first_seen_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    adoption.tuple.libraryID.description,
                    adoption.tuple.hostAuthorityID.rawBytes,
                    adoption.authorityPublicKeyX963,
                    try ClientStoreCoding.sqliteInteger(
                        adoption.transportSet.epoch,
                        field: "transportEpoch"
                    ),
                    adoption.transportSet.exactSignedBytes,
                    nowMS,
                    nowMS,
                ]
            )
        case .advanced:
            guard prior != nil else {
                throw ClientStoreError.missingRow(entity: "trust namespace")
            }
            try db.execute(
                sql: """
                    UPDATE trust_namespaces
                    SET highest_transport_epoch = ?, exact_transport_set = ?, updated_at_ms = ?
                    WHERE library_id = ? AND host_authority_id = ?
                    """,
                arguments: [
                    try ClientStoreCoding.sqliteInteger(
                        adoption.transportSet.epoch,
                        field: "transportEpoch"
                    ),
                    adoption.transportSet.exactSignedBytes,
                    nowMS,
                    adoption.tuple.libraryID.description,
                    adoption.tuple.hostAuthorityID.rawBytes,
                ]
            )
        case .exactReplay:
            break
        }
    }

    private struct GrantRow {
        let slot: VerifiedDeviceGrantSlot

        var grantID: GrantID { slot.grantID }
        var deviceID: DeviceID { slot.deviceID }
        var epoch: UInt64 { slot.registryEpoch }
        var status: StoredGrantStatus { slot.status }
        var exactGrant: Data { slot.exactSignedBytes }
    }

    private func latestGrantRow(
        tuple: AdoptedTrustTuple,
        in db: Database
    ) throws -> GrantRow? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT grant_id, device_id, device_public_key_x963,
                       protocol_major, protocol_minor, scopes_json,
                       grant_epoch, issued_at_ms, expires_at_ms,
                       minimum_compatible_protocol_minor,
                       maximum_compatible_protocol_minor,
                       status, exact_grant
                FROM grant_slots
                WHERE library_id = ? AND host_authority_id = ?
                ORDER BY grant_epoch DESC
                LIMIT 1
                """,
            arguments: [tuple.libraryID.description, tuple.hostAuthorityID.rawBytes]
        ) else { return nil }
        return GrantRow(slot: try verifiedGrantSlot(from: row, tuple: tuple))
    }

    private func grantRow(
        tuple: AdoptedTrustTuple,
        epoch: UInt64,
        in db: Database
    ) throws -> GrantRow? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT grant_id, device_id, device_public_key_x963,
                       protocol_major, protocol_minor, scopes_json,
                       grant_epoch, issued_at_ms, expires_at_ms,
                       minimum_compatible_protocol_minor,
                       maximum_compatible_protocol_minor,
                       status, exact_grant
                FROM grant_slots
                WHERE library_id = ? AND host_authority_id = ? AND grant_epoch = ?
                """,
            arguments: [
                tuple.libraryID.description,
                tuple.hostAuthorityID.rawBytes,
                try ClientStoreCoding.sqliteInteger(epoch, field: "grantEpoch"),
            ]
        ) else { return nil }
        return GrantRow(slot: try verifiedGrantSlot(from: row, tuple: tuple))
    }

    private func verifiedGrantSlot(
        from row: Row,
        tuple: AdoptedTrustTuple
    ) throws -> VerifiedDeviceGrantSlot {
        guard
            let grantUUID = UUID(uuidString: row["grant_id"] as String),
            let status = StoredGrantStatus(rawValue: row["status"] as String)
        else {
            throw ClientStoreError.corruptStoredValue(field: "grantSlot")
        }
        let protocolMajor = try storedUInt16(
            row["protocol_major"],
            field: "grantProtocolMajor"
        )
        let protocolMinor = try storedUInt16(
            row["protocol_minor"],
            field: "grantProtocolMinor"
        )
        let protocolVersion: ClientGrantProtocolVersion
        do {
            protocolVersion = try ClientGrantProtocolVersion(
                major: protocolMajor,
                minor: protocolMinor
            )
        } catch {
            throw ClientStoreError.corruptStoredValue(field: "grantClaims")
        }
        return try VerifiedDeviceGrantSlot(
            tuple: tuple,
            protocolVersion: protocolVersion,
            grantID: GrantID(grantUUID),
            deviceID: try DeviceID(row["device_id"] as Data),
            devicePublicKeyX963: row["device_public_key_x963"] as Data,
            scopes: ClientStoreCoding.decode(
                [ClientAuthorizationScope].self,
                from: row["scopes_json"] as Data,
                field: "grantScopes"
            ),
            registryEpoch: ClientStoreCoding.unsigned(
                row["grant_epoch"],
                field: "grantEpoch"
            ),
            issuedAt: ClientStoreCoding.date(milliseconds: row["issued_at_ms"]),
            expiresAt: (row["expires_at_ms"] as Int64?).map {
                ClientStoreCoding.date(milliseconds: $0)
            },
            minimumCompatibleProtocolMinor: storedUInt16(
                row["minimum_compatible_protocol_minor"],
                field: "grantMinimumCompatibleProtocolMinor"
            ),
            maximumCompatibleProtocolMinor: storedUInt16(
                row["maximum_compatible_protocol_minor"],
                field: "grantMaximumCompatibleProtocolMinor"
            ),
            status: status,
            exactSignedBytes: row["exact_grant"]
        )
    }

    private func storedUInt16(_ value: Int64, field: String) throws -> UInt16 {
        guard let result = UInt16(exactly: value) else {
            throw ClientStoreError.corruptStoredValue(field: field)
        }
        return result
    }

    private func validateGrantUpdate(
        _ grant: VerifiedDeviceGrantSlot,
        tuple: AdoptedTrustTuple,
        transition: GrantTransition,
        in db: Database
    ) throws -> EpochPersistenceDisposition {
        guard grant.tuple == tuple else {
            throw ClientStoreError.trustEvidenceBindingMismatch(field: "grant.tuple")
        }
        guard let row = try latestGrantRow(tuple: tuple, in: db) else {
            guard transition != .revokedReadoption else {
                throw ClientStoreError.readoptionRequiresRevokedGrant
            }
            return .inserted
        }
        if grant.registryEpoch == row.epoch {
            guard grant.exactSignedBytes == row.exactGrant else {
                throw ClientStoreError.grantEpochEquivocation(epoch: grant.registryEpoch)
            }
            guard grant == row.slot else {
                throw ClientStoreError.grantIdentityEquivocation(epoch: grant.registryEpoch)
            }
            if transition == .revokedReadoption {
                try validateRevokedReadoptionReplay(
                    grant,
                    tuple: tuple,
                    current: row,
                    in: db
                )
            }
            return .exactReplay(epoch: grant.registryEpoch)
        }
        let next = try nextGrantEpoch(after: row.epoch)
        guard grant.registryEpoch == next else {
            throw ClientStoreError.grantEpochNotNext(
                expected: next,
                presented: grant.registryEpoch
            )
        }

        switch transition {
        case .ordinary, .authorityReplacement:
            guard grant.grantID == row.grantID,
                  grant.deviceID == row.deviceID else {
                throw ClientStoreError.grantIdentityEquivocation(epoch: grant.registryEpoch)
            }
            if row.status == .revoked, grant.status != .revoked {
                throw ClientStoreError.grantRevivalRequiresExplicitReadoption
            }
        case .revokedReadoption:
            guard row.status == .revoked else {
                throw ClientStoreError.readoptionRequiresRevokedGrant
            }
            guard grant.status == .active else {
                throw ClientStoreError.nonauthorizingGrantStatus(grant.status.rawValue)
            }
            guard grant.deviceID == row.deviceID,
                  grant.grantID != row.grantID else {
                throw ClientStoreError.grantIdentityEquivocation(epoch: grant.registryEpoch)
            }
        }
        return .advanced(previous: row.epoch, current: grant.registryEpoch)
    }

    private func validateRevokedReadoptionReplay(
        _ grant: VerifiedDeviceGrantSlot,
        tuple: AdoptedTrustTuple,
        current: GrantRow,
        in db: Database
    ) throws {
        guard current.status == .active,
              current.epoch > 1,
              let prior = try grantRow(tuple: tuple, epoch: current.epoch - 1, in: db),
              prior.status == .revoked,
              prior.deviceID == grant.deviceID,
              prior.grantID != grant.grantID else {
            throw ClientStoreError.readoptionRequiresRevokedGrant
        }

        let currentAdoptionCount = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM adoption_history
                WHERE library_id = ? AND host_authority_id = ?
                  AND grant_epoch = ? AND ended_at_ms IS NULL
                """,
            arguments: [
                tuple.libraryID.description,
                tuple.hostAuthorityID.rawBytes,
                try ClientStoreCoding.sqliteInteger(current.epoch, field: "grantEpoch"),
            ]
        ) ?? 0
        let priorAdoptionCount = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM adoption_history
                WHERE library_id = ? AND host_authority_id = ?
                  AND grant_epoch = ? AND ended_at_ms IS NOT NULL
                """,
            arguments: [
                tuple.libraryID.description,
                tuple.hostAuthorityID.rawBytes,
                try ClientStoreCoding.sqliteInteger(prior.epoch, field: "grantEpoch"),
            ]
        ) ?? 0
        guard currentAdoptionCount == 1, priorAdoptionCount > 0 else {
            throw ClientStoreError.readoptionRequiresRevokedGrant
        }
    }

    private func nextGrantEpoch(after epoch: UInt64) throws -> UInt64 {
        let next = epoch.addingReportingOverflow(1)
        guard !next.overflow else {
            throw ClientStoreError.integerOutOfRange(field: "grantEpoch", value: epoch)
        }
        return next.partialValue
    }

    private func persistGrant(
        _ grant: VerifiedDeviceGrantSlot,
        tuple: AdoptedTrustTuple,
        disposition: EpochPersistenceDisposition,
        storedAtMS: Int64,
        in db: Database
    ) throws {
        guard grant.tuple == tuple else {
            throw ClientStoreError.trustEvidenceBindingMismatch(field: "grant.tuple")
        }
        if case .exactReplay = disposition { return }
        try db.execute(
            sql: """
                INSERT INTO grant_slots (
                    library_id, host_authority_id, grant_epoch, grant_id,
                    device_id, device_public_key_x963,
                    protocol_major, protocol_minor, scopes_json,
                    issued_at_ms, expires_at_ms,
                    minimum_compatible_protocol_minor,
                    maximum_compatible_protocol_minor,
                    status, exact_grant, stored_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                tuple.libraryID.description,
                tuple.hostAuthorityID.rawBytes,
                try ClientStoreCoding.sqliteInteger(grant.registryEpoch, field: "grantEpoch"),
                grant.grantID.description,
                grant.deviceID.rawBytes,
                grant.devicePublicKeyX963,
                Int64(grant.protocolVersion.major),
                Int64(grant.protocolVersion.minor),
                try ClientStoreCoding.encode(grant.scopes),
                try ClientStoreCoding.milliseconds(grant.issuedAt),
                try grant.expiresAt.map(ClientStoreCoding.milliseconds),
                Int64(grant.minimumCompatibleProtocolMinor),
                Int64(grant.maximumCompatibleProtocolMinor),
                grant.status.rawValue,
                grant.exactSignedBytes,
                storedAtMS,
            ]
        )
    }

    func requireActive(
        _ tuple: AdoptedTrustTuple,
        requiredScope: ClientAuthorizationScope,
        in db: Database
    ) throws {
        let active = try requireSelected(tuple, in: db)
        try requireAuthorizingGrant(active.grant, requiredScope: requiredScope)
    }

    func requireActive(
        _ tuple: AdoptedTrustTuple,
        authorityPublicKeyX963: Data,
        requiredScope: ClientAuthorizationScope,
        in db: Database
    ) throws {
        let active = try requireSelected(tuple, in: db)
        try requireAuthorizingGrant(active.grant, requiredScope: requiredScope)
        guard active.authorityPublicKeyX963 == authorityPublicKeyX963 else {
            throw ClientStoreError.authorityKeyEquivocation
        }
    }

    @discardableResult
    private func requireSelected(
        _ tuple: AdoptedTrustTuple,
        in db: Database
    ) throws -> ActiveAdoptionSnapshot {
        guard let active = try activeAdoption(in: db) else {
            throw ClientStoreError.noActiveAdoption
        }
        guard active.tuple == tuple else {
            throw ClientStoreError.inactiveTrustTuple(
                libraryID: tuple.libraryID,
                hostAuthorityID: tuple.hostAuthorityID
            )
        }
        return active
    }

    private func validateAuthorityReplacementSelection(
        _ replacement: VerifiedAuthorityReplacement,
        in db: Database
    ) throws {
        guard let active = try activeAdoption(in: db) else {
            throw ClientStoreError.authorityReplacementSelectionMismatch
        }
        try validateAuthorityReplacementSelection(replacement, active: active)
    }

    private func validateAuthorityReplacementSelection(
        _ replacement: VerifiedAuthorityReplacement,
        active: ActiveAdoptionSnapshot
    ) throws {
        let replacing = replacement.replacingHostTrust
        guard active.tuple.libraryID == replacing.libraryID,
              active.tuple.hostAuthorityID == replacing.hostAuthorityID,
              active.authorityPublicKeyX963 == replacing.hostAuthorityPublicKeyX963,
              replacement.replacement.tuple.libraryID == replacing.libraryID,
              replacement.replacement.tuple.hostAuthorityID
                != replacing.hostAuthorityID else {
            throw ClientStoreError.authorityReplacementSelectionMismatch
        }
    }

    private func requireAuthorizingGrant(
        _ grant: VerifiedDeviceGrantSlot,
        requiredScope: ClientAuthorizationScope
    ) throws {
        guard grant.deviceID == installationDeviceID else {
            throw ClientStoreError.grantDeviceMismatch(
                expected: installationDeviceID,
                presented: grant.deviceID
            )
        }
        guard grant.status == .active else {
            throw ClientStoreError.nonauthorizingGrantStatus(grant.status.rawValue)
        }
        let checkedAt = now()
        guard checkedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ClientStoreError.corruptStoredValue(field: "authorizationClock")
        }
        let clientMinor = ClientGrantProtocolVersion.v1.minor
        guard grant.minimumCompatibleProtocolMinor <= clientMinor,
              clientMinor <= grant.maximumCompatibleProtocolMinor else {
            throw ClientStoreError.grantProtocolIncompatible(
                clientMinor: clientMinor,
                minimum: grant.minimumCompatibleProtocolMinor,
                maximum: grant.maximumCompatibleProtocolMinor
            )
        }
        if let expiresAt = grant.expiresAt, checkedAt >= expiresAt {
            throw ClientStoreError.grantExpired
        }
        guard grant.scopes.contains(requiredScope) else {
            throw ClientStoreError.grantMissingRequiredScope(requiredScope)
        }
    }

    private func activeAdoption(in db: Database) throws -> ActiveAdoptionSnapshot? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT ah.adoption_id, ah.library_id, ah.host_authority_id,
                       ah.adopted_at_ms,
                       tn.authority_public_key_x963,
                       tn.highest_transport_epoch, tn.exact_transport_set,
                       gs.grant_id, gs.device_id, gs.device_public_key_x963,
                       gs.protocol_major, gs.protocol_minor, gs.scopes_json,
                       gs.grant_epoch, gs.issued_at_ms, gs.expires_at_ms,
                       gs.minimum_compatible_protocol_minor,
                       gs.maximum_compatible_protocol_minor,
                       gs.status, gs.exact_grant
                FROM adoption_history ah
                JOIN trust_namespaces tn
                  ON tn.library_id = ah.library_id
                 AND tn.host_authority_id = ah.host_authority_id
                JOIN grant_slots gs
                  ON gs.library_id = ah.library_id
                 AND gs.host_authority_id = ah.host_authority_id
                 AND gs.grant_epoch = ah.grant_epoch
                WHERE ah.ended_at_ms IS NULL
                LIMIT 1
                """
        ) else { return nil }

        guard
            let adoptionID = UUID(uuidString: row["adoption_id"] as String),
            let libraryUUID = UUID(uuidString: row["library_id"] as String)
        else {
            throw ClientStoreError.corruptStoredValue(field: "activeAdoption")
        }
        let tuple = AdoptedTrustTuple(
            libraryID: LibraryID(libraryUUID),
            hostAuthorityID: try HostAuthorityID(row["host_authority_id"] as Data)
        )
        let authorityBinding: RecordingHostTrustBinding
        do {
            authorityBinding = try RecordingHostTrustBinding(
                libraryID: tuple.libraryID,
                hostAuthorityID: tuple.hostAuthorityID,
                hostAuthorityPublicKeyX963: row["authority_public_key_x963"] as Data
            )
        } catch TransferValidationError.evidenceBindingMismatch {
            throw ClientStoreError.hostAuthorityIdentityMismatch
        } catch {
            throw ClientStoreError.corruptStoredValue(field: "authorityPublicKeyX963")
        }
        return ActiveAdoptionSnapshot(
            adoptionID: adoptionID,
            tuple: tuple,
            authorityPublicKeyX963: authorityBinding.hostAuthorityPublicKeyX963,
            transportSet: try VerifiedTransportSetSlot(
                tuple: tuple,
                epoch: ClientStoreCoding.unsigned(
                    row["highest_transport_epoch"],
                    field: "transportEpoch"
                ),
                exactSignedBytes: row["exact_transport_set"]
            ),
            grant: try verifiedGrantSlot(from: row, tuple: tuple),
            adoptedAt: ClientStoreCoding.date(milliseconds: row["adopted_at_ms"])
        )
    }
}
