import Foundation
import HarcDomain
import HarcIdentity

/// The authorization state mirrored from a validator-owned registry object.
/// The exact signed bytes remain the source of truth; this value is only the
/// independently checked field used by client persistence and authorization.
public enum ValidatedDeviceGrantStatus: String, CaseIterable, Sendable {
    case active
    case revoked
    case trustRepairRequired
}

/// Scope projection owned by the transfer boundary. Client persistence uses
/// this type without reaching backward through HarcTransfer into HarcIdentity.
public enum ClientAuthorizationScope: String, Codable, CaseIterable, Sendable,
    Comparable {
    case recordingUploadOwn = "recording.upload.own"
    case recordingReadOwn = "recording.read.own"
    case libraryMetadataRead = "library.metadata.read"
    case libraryTranscriptRead = "library.transcript.read"
    case libraryAudioRead = "library.audio.read"
    case libraryMetadataWrite = "library.metadata.write"
    case processingSubmitOwn = "processing.submit.own"

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    package init(_ scope: AuthorizationScope) {
        // The registered values are exhaustively mirrored above.
        self = Self(rawValue: scope.rawValue)!
    }

    package var identityScope: AuthorizationScope {
        AuthorizationScope(rawValue: rawValue)!
    }
}

/// Identity protocol version projected across the transfer boundary without
/// exposing HarcIdentity as a dependency of client persistence.
public struct ClientGrantProtocolVersion: Equatable, Hashable, Codable, Sendable {
    public static let harcV1Major: UInt16 = 1
    public static let v1 = try! Self(minor: 0)

    public let major: UInt16
    public let minor: UInt16

    public init(major: UInt16 = Self.harcV1Major, minor: UInt16) throws {
        guard major == Self.harcV1Major else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "grant.protocolMajor"
            )
        }
        self.major = major
        self.minor = minor
    }

    private enum CodingKeys: String, CodingKey { case major, minor }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                major: container.decode(UInt16.self, forKey: .major),
                minor: container.decode(UInt16.self, forKey: .minor)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid client grant protocol version.",
                    underlyingError: error
                )
            )
        }
    }
}

/// Structurally validated, path-free grant claims suitable for durable client
/// persistence. HarcTransfer performs the Identity-backed public-key, scope,
/// date, epoch, and compatibility validation; HarcClientStore only receives
/// this projection and the exact signed bytes.
public struct ValidatedClientGrantClaimsProjection: Equatable, Hashable, Sendable {
    public let protocolVersion: ClientGrantProtocolVersion
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let grantID: GrantID
    public let deviceID: DeviceID
    public let devicePublicKeyX963: Data
    public let scopes: [ClientAuthorizationScope]
    public let registryEpoch: UInt64
    public let issuedAt: Date
    public let expiresAt: Date?
    public let minimumCompatibleProtocolMinor: UInt16
    public let maximumCompatibleProtocolMinor: UInt16

    /// Revalidates a durable projection on database reopen. This is structural
    /// claims validation, not signature validation; only validator-created
    /// evidence can enter the persistence API in the first place.
    public init(
        protocolVersion: ClientGrantProtocolVersion,
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        grantID: GrantID,
        deviceID: DeviceID,
        devicePublicKeyX963: Data,
        scopes: [ClientAuthorizationScope],
        registryEpoch: UInt64,
        issuedAt: Date,
        expiresAt: Date?,
        minimumCompatibleProtocolMinor: UInt16,
        maximumCompatibleProtocolMinor: UInt16
    ) throws {
        do {
            let identityVersion = try IdentityProtocolVersion(
                major: protocolVersion.major,
                minor: protocolVersion.minor
            )
            let publicKey = try P256X963PublicKey(devicePublicKeyX963)
            _ = try DeviceGrantClaims(
                protocolVersion: identityVersion,
                libraryID: libraryID,
                hostAuthorityID: hostAuthorityID,
                grantID: grantID,
                deviceID: deviceID,
                devicePublicKey: publicKey,
                scopes: scopes.map(\.identityScope),
                grantEpoch: GrantEpoch(registryEpoch),
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                minimumCompatibleProtocolMinor: minimumCompatibleProtocolMinor,
                maximumCompatibleProtocolMinor: maximumCompatibleProtocolMinor
            )
        } catch {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "grant.claimsProjection"
            )
        }
        self.protocolVersion = protocolVersion
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        self.grantID = grantID
        self.deviceID = deviceID
        self.devicePublicKeyX963 = devicePublicKeyX963
        self.scopes = scopes
        self.registryEpoch = registryEpoch
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.minimumCompatibleProtocolMinor = minimumCompatibleProtocolMinor
        self.maximumCompatibleProtocolMinor = maximumCompatibleProtocolMinor
    }

    package init(claims: DeviceGrantClaims) throws {
        try self.init(
            protocolVersion: ClientGrantProtocolVersion(
                major: claims.protocolVersion.major,
                minor: claims.protocolVersion.minor
            ),
            libraryID: claims.libraryID,
            hostAuthorityID: claims.hostAuthorityID,
            grantID: claims.grantID,
            deviceID: claims.deviceID,
            devicePublicKeyX963: claims.devicePublicKey.rawBytes,
            scopes: claims.scopes.map(ClientAuthorizationScope.init),
            registryEpoch: claims.grantEpoch.rawValue,
            issuedAt: claims.issuedAt,
            expiresAt: claims.expiresAt,
            minimumCompatibleProtocolMinor: claims.minimumCompatibleProtocolMinor,
            maximumCompatibleProtocolMinor: claims.maximumCompatibleProtocolMinor
        )
    }
}

/// Concrete transport-set evidence emitted only after the future PR 4
/// validator has verified the authority signature and mirrored the exact host
/// tuple and epoch from the signed payload.
public struct ValidatedTransportSetEvidence: Equatable, Hashable, Sendable {
    public let hostTrust: RecordingHostTrustBinding
    public let epoch: UInt64
    public let exactSignedBytes: Data

    /// Package access is the validator construction seam. External clients can
    /// consume evidence returned by a validator but cannot manufacture it.
    package init(
        hostTrust: RecordingHostTrustBinding,
        epoch: UInt64,
        exactSignedBytes: Data
    ) throws {
        guard epoch > 0 else {
            throw TransferValidationError.evidenceBindingMismatch(field: "transportEpoch")
        }
        guard !exactSignedBytes.isEmpty else {
            throw TransferValidationError.emptyExactObject
        }
        self.hostTrust = hostTrust
        self.epoch = epoch
        self.exactSignedBytes = exactSignedBytes
    }
}

/// Concrete grant/registry evidence emitted only after the future PR 4
/// validator has verified the signed object. `DeviceGrantClaims` supplies the
/// canonical LibraryID, HostAuthorityID, GrantID, DeviceID, and registry epoch
/// rather than accepting a second independently swappable tuple.
public struct ValidatedDeviceGrantEvidence: Equatable, Hashable, Sendable {
    public let hostTrust: RecordingHostTrustBinding
    public let protocolVersion: IdentityProtocolVersion
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let grantID: GrantID
    public let deviceID: DeviceID
    public let devicePublicKey: P256X963PublicKey
    public let scopes: [AuthorizationScope]
    public let registryEpoch: UInt64
    public let issuedAt: Date
    public let expiresAt: Date?
    public let minimumCompatibleProtocolMinor: UInt16
    public let maximumCompatibleProtocolMinor: UInt16
    public let status: ValidatedDeviceGrantStatus
    public let exactSignedBytes: Data
    public let clientClaims: ValidatedClientGrantClaimsProjection

    /// Package access is the validator construction seam. The claims are
    /// copied only after their tuple has been compared with the exact authority
    /// binding used to validate the signed bytes.
    package init(
        hostTrust: RecordingHostTrustBinding,
        claims: DeviceGrantClaims,
        status: ValidatedDeviceGrantStatus,
        exactSignedBytes: Data
    ) throws {
        guard claims.libraryID == hostTrust.libraryID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "grant.libraryID")
        }
        guard claims.hostAuthorityID == hostTrust.hostAuthorityID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "grant.hostAuthorityID")
        }
        guard !exactSignedBytes.isEmpty else {
            throw TransferValidationError.emptyExactObject
        }
        self.hostTrust = hostTrust
        protocolVersion = claims.protocolVersion
        libraryID = claims.libraryID
        hostAuthorityID = claims.hostAuthorityID
        grantID = claims.grantID
        deviceID = claims.deviceID
        devicePublicKey = claims.devicePublicKey
        scopes = claims.scopes
        registryEpoch = claims.grantEpoch.rawValue
        issuedAt = claims.issuedAt
        expiresAt = claims.expiresAt
        minimumCompatibleProtocolMinor = claims.minimumCompatibleProtocolMinor
        maximumCompatibleProtocolMinor = claims.maximumCompatibleProtocolMinor
        self.status = status
        self.exactSignedBytes = exactSignedBytes
        clientClaims = try ValidatedClientGrantClaimsProjection(claims: claims)
    }
}

/// One fully bound adoption result. The package-only initializer prevents
/// callers outside Harc's validator boundary from combining evidence slots
/// that were verified for different hosts.
public struct ValidatedClientAdoptionEvidence: Equatable, Hashable, Sendable {
    public let hostTrust: RecordingHostTrustBinding
    public let transportSet: ValidatedTransportSetEvidence
    public let grant: ValidatedDeviceGrantEvidence
    public let adoptedAt: Date

    package init(
        hostTrust: RecordingHostTrustBinding,
        transportSet: ValidatedTransportSetEvidence,
        grant: ValidatedDeviceGrantEvidence,
        adoptedAt: Date
    ) throws {
        guard transportSet.hostTrust == hostTrust else {
            throw TransferValidationError.evidenceBindingMismatch(field: "transportSet.hostTrust")
        }
        guard grant.hostTrust == hostTrust,
              grant.libraryID == hostTrust.libraryID,
              grant.hostAuthorityID == hostTrust.hostAuthorityID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "grant.hostTrust")
        }
        try TransferValidation.requireFinite(
            adoptedAt,
            field: "ValidatedClientAdoptionEvidence.adoptedAt"
        )
        self.hostTrust = hostTrust
        self.transportSet = transportSet
        self.grant = grant
        self.adoptedAt = adoptedAt
    }
}

/// Validator-owned evidence for the security-sensitive case where a remembered
/// library is presented under a different host authority. Keeping this
/// transition distinct from ordinary adoption prevents a newly scanned QR code
/// from silently replacing the authority already anchored for that LibraryID.
public struct ValidatedClientAuthorityReplacementEvidence: Equatable, Hashable, Sendable {
    public let replacingHostTrust: RecordingHostTrustBinding
    public let replacementAdoption: ValidatedClientAdoptionEvidence

    /// Package access is the validator construction seam. The prior authority
    /// binding comes from the client anchor inspected by the pairing validator;
    /// the replacement adoption comes from the newly verified QR flow.
    package init(
        replacingHostTrust: RecordingHostTrustBinding,
        replacementAdoption: ValidatedClientAdoptionEvidence
    ) throws {
        guard replacingHostTrust.libraryID == replacementAdoption.hostTrust.libraryID else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "authorityReplacement.libraryID"
            )
        }
        guard replacingHostTrust.hostAuthorityID
                != replacementAdoption.hostTrust.hostAuthorityID else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "authorityReplacement.hostAuthorityID"
            )
        }
        self.replacingHostTrust = replacingHostTrust
        self.replacementAdoption = replacementAdoption
    }
}
