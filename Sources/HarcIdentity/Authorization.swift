import Foundation
import HarcDomain

public enum AuthorizationScope: String, Codable, CaseIterable, Sendable, Comparable {
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

    public var isLibraryScope: Bool { rawValue.hasPrefix("library.") }
}

public enum AdoptedClientKind: String, Codable, CaseIterable, Sendable {
    case mobile
    case macClient
}

public enum ScopePolicy {
    public static func minimalScopes(for client: AdoptedClientKind) -> [AuthorizationScope] {
        var scopes: [AuthorizationScope] = [
            .recordingReadOwn,
            .recordingUploadOwn,
        ]
        if client == .macClient {
            scopes.append(.processingSubmitOwn)
        }
        return scopes.sorted()
    }

    /// Initial pairing may issue only the selected client kind's minimal scope
    /// set without local OS authentication. Canonical ordering, duplicates, and
    /// the nonempty-grant invariant are validated by `DeviceGrantClaims`.
    public static func initialGrantRequiresOSAuthentication(
        scopes: some Sequence<AuthorizationScope>,
        for client: AdoptedClientKind
    ) -> Bool {
        !Set(scopes).isSubset(of: Set(minimalScopes(for: client)))
    }

    /// Every later scope change requires local OS authentication, including a
    /// narrowing change, because it advances the live grant epoch.
    public static var scopeChangeRequiresOSAuthentication: Bool { true }
}

/// The version carried by V1 identity claims. Keeping major and minor in one
/// validated value prevents an unsupported major from entering grant,
/// revocation, or registry state through either an initializer or Codable.
public struct IdentityProtocolVersion: Hashable, Sendable, Codable {
    public static let harcV1Major: UInt16 = 1
    public static let v1 = try! Self(minor: 0)

    public let major: UInt16
    public let minor: UInt16

    public init(major: UInt16 = Self.harcV1Major, minor: UInt16) throws {
        guard major == Self.harcV1Major else {
            throw AuthorizationModelError.unsupportedProtocolMajor(major)
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
                    debugDescription: "Invalid identity protocol version.",
                    underlyingError: error
                )
            )
        }
    }
}

public enum AuthorizationModelError: Error, Equatable, Sendable {
    case unsupportedProtocolMajor(UInt16)
    case grantProtocolVersionMismatch(
        expected: IdentityProtocolVersion,
        presented: IdentityProtocolVersion
    )
    case zeroGrantEpoch
    case grantEpochOverflow
    case emptyScopes
    case scopesNotCanonical
    case duplicateScope
    case deviceKeyMismatch
    case invalidIssueDate
    case invalidExpiry
    case invalidReasonCode
    case invalidProtocolCompatibilityRange
    case invalidRegistryState
    case grantLibraryMismatch
    case grantAuthorityMismatch
    case grantDeviceMismatch
    case grantPublicKeyMismatch
    case grantIDMismatch
    case grantEpochMismatch(expected: GrantEpoch, presented: GrantEpoch)
    case deviceRevoked
    case grantExpired
    case missingScope(AuthorizationScope)
}

public struct GrantEpoch: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) throws {
        guard rawValue > 0 else { throw AuthorizationModelError.zeroGrantEpoch }
        self.rawValue = rawValue
    }

    public static let initial = try! GrantEpoch(1)

    public func next() throws -> Self {
        guard rawValue < UInt64.max else {
            throw AuthorizationModelError.grantEpochOverflow
        }
        return try Self(rawValue + 1)
    }

    public var description: String { String(rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(container.decode(UInt64.self))
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "A grant epoch must be greater than zero.",
                    underlyingError: error
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Validated grant fields independent of the PR4 protobuf encoding and signed
/// envelope. This model must not be treated as signed bytes by itself.
public struct DeviceGrantClaims: Hashable, Sendable, Codable {
    public let protocolVersion: IdentityProtocolVersion
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let grantID: GrantID
    public let deviceID: DeviceID
    public let devicePublicKey: P256X963PublicKey
    public let scopes: [AuthorizationScope]
    public let grantEpoch: GrantEpoch
    public let issuedAt: Date
    public let expiresAt: Date?
    public let minimumCompatibleProtocolMinor: UInt16
    public let maximumCompatibleProtocolMinor: UInt16

    public var protocolMajor: UInt16 { protocolVersion.major }
    public var protocolMinor: UInt16 { protocolVersion.minor }

    public init(
        protocolVersion: IdentityProtocolVersion = .v1,
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        grantID: GrantID,
        deviceID: DeviceID,
        devicePublicKey: P256X963PublicKey,
        scopes: [AuthorizationScope],
        grantEpoch: GrantEpoch,
        issuedAt: Date,
        expiresAt: Date? = nil,
        minimumCompatibleProtocolMinor: UInt16,
        maximumCompatibleProtocolMinor: UInt16
    ) throws {
        guard devicePublicKey.deviceID == deviceID else {
            throw AuthorizationModelError.deviceKeyMismatch
        }
        guard !scopes.isEmpty else { throw AuthorizationModelError.emptyScopes }
        guard scopes == scopes.sorted() else {
            throw AuthorizationModelError.scopesNotCanonical
        }
        guard Set(scopes).count == scopes.count else {
            throw AuthorizationModelError.duplicateScope
        }
        guard issuedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw AuthorizationModelError.invalidIssueDate
        }
        if let expiresAt {
            guard
                expiresAt.timeIntervalSinceReferenceDate.isFinite,
                expiresAt > issuedAt
            else {
                throw AuthorizationModelError.invalidExpiry
            }
        }
        guard
            minimumCompatibleProtocolMinor <= protocolVersion.minor,
            protocolVersion.minor <= maximumCompatibleProtocolMinor
        else {
            throw AuthorizationModelError.invalidProtocolCompatibilityRange
        }

        self.protocolVersion = protocolVersion
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        self.grantID = grantID
        self.deviceID = deviceID
        self.devicePublicKey = devicePublicKey
        self.scopes = scopes
        self.grantEpoch = grantEpoch
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.minimumCompatibleProtocolMinor = minimumCompatibleProtocolMinor
        self.maximumCompatibleProtocolMinor = maximumCompatibleProtocolMinor
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case libraryID
        case hostAuthorityID
        case grantID
        case deviceID
        case devicePublicKey
        case scopes
        case grantEpoch
        case issuedAt
        case expiresAt
        case minimumCompatibleProtocolMinor
        case maximumCompatibleProtocolMinor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                protocolVersion: container.decode(IdentityProtocolVersion.self, forKey: .protocolVersion),
                libraryID: container.decode(LibraryID.self, forKey: .libraryID),
                hostAuthorityID: container.decode(HostAuthorityID.self, forKey: .hostAuthorityID),
                grantID: container.decode(GrantID.self, forKey: .grantID),
                deviceID: container.decode(DeviceID.self, forKey: .deviceID),
                devicePublicKey: container.decode(P256X963PublicKey.self, forKey: .devicePublicKey),
                scopes: container.decode([AuthorizationScope].self, forKey: .scopes),
                grantEpoch: container.decode(GrantEpoch.self, forKey: .grantEpoch),
                issuedAt: container.decode(Date.self, forKey: .issuedAt),
                expiresAt: container.decodeIfPresent(Date.self, forKey: .expiresAt),
                minimumCompatibleProtocolMinor: container.decode(
                    UInt16.self,
                    forKey: .minimumCompatibleProtocolMinor
                ),
                maximumCompatibleProtocolMinor: container.decode(
                    UInt16.self,
                    forKey: .maximumCompatibleProtocolMinor
                )
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid device grant claims.",
                    underlyingError: error
                )
            )
        }
    }

    public init(
        protocolVersion: IdentityProtocolVersion = .v1,
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        grantID: GrantID,
        devicePublicKey: P256X963PublicKey,
        scopes: Set<AuthorizationScope>,
        grantEpoch: GrantEpoch,
        issuedAt: Date,
        expiresAt: Date? = nil,
        minimumCompatibleProtocolMinor: UInt16,
        maximumCompatibleProtocolMinor: UInt16
    ) throws {
        try self.init(
            protocolVersion: protocolVersion,
            libraryID: libraryID,
            hostAuthorityID: hostAuthorityID,
            grantID: grantID,
            deviceID: devicePublicKey.deviceID,
            devicePublicKey: devicePublicKey,
            scopes: scopes.sorted(),
            grantEpoch: grantEpoch,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            minimumCompatibleProtocolMinor: minimumCompatibleProtocolMinor,
            maximumCompatibleProtocolMinor: maximumCompatibleProtocolMinor
        )
    }
}

public enum DeviceRegistryStatus: String, Codable, Sendable {
    case active
    case revoked
}

/// Transport-neutral revocation facts. PR4 defines their exact protobuf and
/// envelope bytes.
public struct DeviceRevocationClaims: Hashable, Sendable, Codable {
    public let protocolVersion: IdentityProtocolVersion
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let deviceID: DeviceID
    public let grantID: GrantID
    public let priorGrantEpoch: GrantEpoch
    public let newGrantEpoch: GrantEpoch
    public let revocationID: UUID
    public let reasonCode: String
    public let issuedAt: Date

    public var protocolMajor: UInt16 { protocolVersion.major }
    public var protocolMinor: UInt16 { protocolVersion.minor }

    public init(
        protocolVersion: IdentityProtocolVersion = .v1,
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        deviceID: DeviceID,
        grantID: GrantID,
        priorGrantEpoch: GrantEpoch,
        newGrantEpoch: GrantEpoch,
        revocationID: UUID,
        reasonCode: String,
        issuedAt: Date
    ) throws {
        let expectedNewEpoch = try priorGrantEpoch.next()
        guard newGrantEpoch == expectedNewEpoch else {
            throw AuthorizationModelError.grantEpochMismatch(
                expected: expectedNewEpoch,
                presented: newGrantEpoch
            )
        }
        guard issuedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw AuthorizationModelError.invalidIssueDate
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard
            !reasonCode.isEmpty,
            reasonCode.count <= 128,
            reasonCode.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw AuthorizationModelError.invalidReasonCode
        }

        self.protocolVersion = protocolVersion
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        self.deviceID = deviceID
        self.grantID = grantID
        self.priorGrantEpoch = priorGrantEpoch
        self.newGrantEpoch = newGrantEpoch
        self.revocationID = revocationID
        self.reasonCode = reasonCode
        self.issuedAt = issuedAt
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case libraryID
        case hostAuthorityID
        case deviceID
        case grantID
        case priorGrantEpoch
        case newGrantEpoch
        case revocationID
        case reasonCode
        case issuedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                protocolVersion: container.decode(IdentityProtocolVersion.self, forKey: .protocolVersion),
                libraryID: container.decode(LibraryID.self, forKey: .libraryID),
                hostAuthorityID: container.decode(HostAuthorityID.self, forKey: .hostAuthorityID),
                deviceID: container.decode(DeviceID.self, forKey: .deviceID),
                grantID: container.decode(GrantID.self, forKey: .grantID),
                priorGrantEpoch: container.decode(GrantEpoch.self, forKey: .priorGrantEpoch),
                newGrantEpoch: container.decode(GrantEpoch.self, forKey: .newGrantEpoch),
                revocationID: container.decode(UUID.self, forKey: .revocationID),
                reasonCode: container.decode(String.self, forKey: .reasonCode),
                issuedAt: container.decode(Date.self, forKey: .issuedAt)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid device revocation claims.",
                    underlyingError: error
                )
            )
        }
    }
}

/// Current server-side authorization state for one device. A signed grant is
/// checked against this state; it never overrides it.
public struct DeviceRegistryEntry: Hashable, Sendable, Codable {
    public let protocolVersion: IdentityProtocolVersion
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let deviceID: DeviceID
    public let devicePublicKey: P256X963PublicKey
    public let currentGrantID: GrantID
    public let currentGrantEpoch: GrantEpoch
    public let currentScopes: [AuthorizationScope]
    public let grantIssuedAt: Date
    public let grantExpiresAt: Date?
    public let minimumCompatibleProtocolMinor: UInt16
    public let maximumCompatibleProtocolMinor: UInt16
    public let status: DeviceRegistryStatus
    public let revocation: DeviceRevocationClaims?

    public var protocolMajor: UInt16 { protocolVersion.major }
    public var protocolMinor: UInt16 { protocolVersion.minor }

    public init(activeGrant: DeviceGrantClaims) {
        self.protocolVersion = activeGrant.protocolVersion
        self.libraryID = activeGrant.libraryID
        self.hostAuthorityID = activeGrant.hostAuthorityID
        self.deviceID = activeGrant.deviceID
        self.devicePublicKey = activeGrant.devicePublicKey
        self.currentGrantID = activeGrant.grantID
        self.currentGrantEpoch = activeGrant.grantEpoch
        self.currentScopes = activeGrant.scopes
        self.grantIssuedAt = activeGrant.issuedAt
        self.grantExpiresAt = activeGrant.expiresAt
        self.minimumCompatibleProtocolMinor = activeGrant.minimumCompatibleProtocolMinor
        self.maximumCompatibleProtocolMinor = activeGrant.maximumCompatibleProtocolMinor
        self.status = .active
        self.revocation = nil
    }

    private init(
        protocolVersion: IdentityProtocolVersion,
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        deviceID: DeviceID,
        devicePublicKey: P256X963PublicKey,
        currentGrantID: GrantID,
        currentGrantEpoch: GrantEpoch,
        currentScopes: [AuthorizationScope],
        grantIssuedAt: Date,
        grantExpiresAt: Date?,
        minimumCompatibleProtocolMinor: UInt16,
        maximumCompatibleProtocolMinor: UInt16,
        status: DeviceRegistryStatus,
        revocation: DeviceRevocationClaims?
    ) {
        self.protocolVersion = protocolVersion
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        self.deviceID = deviceID
        self.devicePublicKey = devicePublicKey
        self.currentGrantID = currentGrantID
        self.currentGrantEpoch = currentGrantEpoch
        self.currentScopes = currentScopes
        self.grantIssuedAt = grantIssuedAt
        self.grantExpiresAt = grantExpiresAt
        self.minimumCompatibleProtocolMinor = minimumCompatibleProtocolMinor
        self.maximumCompatibleProtocolMinor = maximumCompatibleProtocolMinor
        self.status = status
        self.revocation = revocation
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case libraryID
        case hostAuthorityID
        case deviceID
        case devicePublicKey
        case currentGrantID
        case currentGrantEpoch
        case currentScopes
        case grantIssuedAt
        case grantExpiresAt
        case minimumCompatibleProtocolMinor
        case maximumCompatibleProtocolMinor
        case status
        case revocation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            let protocolVersion = try container.decode(IdentityProtocolVersion.self, forKey: .protocolVersion)
            let libraryID = try container.decode(LibraryID.self, forKey: .libraryID)
            let hostAuthorityID = try container.decode(HostAuthorityID.self, forKey: .hostAuthorityID)
            let deviceID = try container.decode(DeviceID.self, forKey: .deviceID)
            let devicePublicKey = try container.decode(P256X963PublicKey.self, forKey: .devicePublicKey)
            let currentGrantID = try container.decode(GrantID.self, forKey: .currentGrantID)
            let currentGrantEpoch = try container.decode(GrantEpoch.self, forKey: .currentGrantEpoch)
            let currentScopes = try container.decode([AuthorizationScope].self, forKey: .currentScopes)
            let grantIssuedAt = try container.decode(Date.self, forKey: .grantIssuedAt)
            let grantExpiresAt = try container.decodeIfPresent(Date.self, forKey: .grantExpiresAt)
            let minimumCompatibleProtocolMinor = try container.decode(
                UInt16.self,
                forKey: .minimumCompatibleProtocolMinor
            )
            let maximumCompatibleProtocolMinor = try container.decode(
                UInt16.self,
                forKey: .maximumCompatibleProtocolMinor
            )
            let status = try container.decode(DeviceRegistryStatus.self, forKey: .status)
            let revocation = try container.decodeIfPresent(DeviceRevocationClaims.self, forKey: .revocation)

            guard
                devicePublicKey.deviceID == deviceID,
                !currentScopes.isEmpty,
                currentScopes == currentScopes.sorted(),
                Set(currentScopes).count == currentScopes.count,
                grantIssuedAt.timeIntervalSinceReferenceDate.isFinite,
                grantExpiresAt.map({
                    $0.timeIntervalSinceReferenceDate.isFinite && $0 > grantIssuedAt
                }) ?? true,
                minimumCompatibleProtocolMinor <= protocolVersion.minor,
                protocolVersion.minor <= maximumCompatibleProtocolMinor,
                (status == .active) == (revocation == nil)
            else {
                throw AuthorizationModelError.invalidRegistryState
            }

            if let revocation {
                guard
                    revocation.libraryID == libraryID,
                    revocation.hostAuthorityID == hostAuthorityID,
                    revocation.deviceID == deviceID,
                    revocation.grantID == currentGrantID,
                    revocation.newGrantEpoch == currentGrantEpoch,
                    revocation.protocolVersion == protocolVersion
                else {
                    throw AuthorizationModelError.invalidRegistryState
                }
            }

            self.init(
                protocolVersion: protocolVersion,
                libraryID: libraryID,
                hostAuthorityID: hostAuthorityID,
                deviceID: deviceID,
                devicePublicKey: devicePublicKey,
                currentGrantID: currentGrantID,
                currentGrantEpoch: currentGrantEpoch,
                currentScopes: currentScopes,
                grantIssuedAt: grantIssuedAt,
                grantExpiresAt: grantExpiresAt,
                minimumCompatibleProtocolMinor: minimumCompatibleProtocolMinor,
                maximumCompatibleProtocolMinor: maximumCompatibleProtocolMinor,
                status: status,
                revocation: revocation
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid device registry entry.",
                    underlyingError: error
                )
            )
        }
    }

    public func authorize(
        grant: DeviceGrantClaims,
        requiredScope: AuthorizationScope,
        at now: Date = Date()
    ) throws {
        guard status == .active else { throw AuthorizationModelError.deviceRevoked }
        guard grant.protocolVersion == protocolVersion else {
            throw AuthorizationModelError.grantProtocolVersionMismatch(
                expected: protocolVersion,
                presented: grant.protocolVersion
            )
        }
        guard grant.libraryID == libraryID else {
            throw AuthorizationModelError.grantLibraryMismatch
        }
        guard grant.hostAuthorityID == hostAuthorityID else {
            throw AuthorizationModelError.grantAuthorityMismatch
        }
        guard grant.deviceID == deviceID else {
            throw AuthorizationModelError.grantDeviceMismatch
        }
        guard grant.devicePublicKey == devicePublicKey else {
            throw AuthorizationModelError.grantPublicKeyMismatch
        }
        guard grant.grantID == currentGrantID else {
            throw AuthorizationModelError.grantIDMismatch
        }
        guard grant.grantEpoch == currentGrantEpoch else {
            throw AuthorizationModelError.grantEpochMismatch(
                expected: currentGrantEpoch,
                presented: grant.grantEpoch
            )
        }
        if let expiresAt = minExpiration(grant.expiresAt, grantExpiresAt), now >= expiresAt {
            throw AuthorizationModelError.grantExpired
        }
        guard
            grant.scopes.contains(requiredScope),
            currentScopes.contains(requiredScope)
        else {
            throw AuthorizationModelError.missingScope(requiredScope)
        }
    }

    /// Pure state transition to call only after the host app has completed the
    /// Section 12 local OS-authentication and security-journal requirements.
    public func replacingScopesAfterLocalAuthorization(
        _ scopes: Set<AuthorizationScope>,
        issuedAt: Date,
        expiresAt: Date? = nil
    ) throws -> (entry: DeviceRegistryEntry, grant: DeviceGrantClaims) {
        guard status == .active else { throw AuthorizationModelError.deviceRevoked }
        let nextEpoch = try currentGrantEpoch.next()
        let grant = try DeviceGrantClaims(
            protocolVersion: protocolVersion,
            libraryID: libraryID,
            hostAuthorityID: hostAuthorityID,
            grantID: currentGrantID,
            devicePublicKey: devicePublicKey,
            scopes: scopes,
            grantEpoch: nextEpoch,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            minimumCompatibleProtocolMinor: minimumCompatibleProtocolMinor,
            maximumCompatibleProtocolMinor: maximumCompatibleProtocolMinor
        )
        return (DeviceRegistryEntry(activeGrant: grant), grant)
    }

    /// Pure state transition to call inside the host's journaled revocation flow.
    public func revoking(
        revocationID: UUID,
        reasonCode: String,
        issuedAt: Date
    ) throws -> (entry: DeviceRegistryEntry, revocation: DeviceRevocationClaims) {
        guard status == .active else { throw AuthorizationModelError.deviceRevoked }
        let nextEpoch = try currentGrantEpoch.next()
        let revocation = try DeviceRevocationClaims(
            protocolVersion: protocolVersion,
            libraryID: libraryID,
            hostAuthorityID: hostAuthorityID,
            deviceID: deviceID,
            grantID: currentGrantID,
            priorGrantEpoch: currentGrantEpoch,
            newGrantEpoch: nextEpoch,
            revocationID: revocationID,
            reasonCode: reasonCode,
            issuedAt: issuedAt
        )
        let entry = DeviceRegistryEntry(
            protocolVersion: protocolVersion,
            libraryID: libraryID,
            hostAuthorityID: hostAuthorityID,
            deviceID: deviceID,
            devicePublicKey: devicePublicKey,
            currentGrantID: currentGrantID,
            currentGrantEpoch: nextEpoch,
            currentScopes: currentScopes,
            grantIssuedAt: grantIssuedAt,
            grantExpiresAt: grantExpiresAt,
            minimumCompatibleProtocolMinor: minimumCompatibleProtocolMinor,
            maximumCompatibleProtocolMinor: maximumCompatibleProtocolMinor,
            status: .revoked,
            revocation: revocation
        )
        return (entry, revocation)
    }

    private func minExpiration(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)): min(lhs, rhs)
        case (.some(let value), .none), (.none, .some(let value)): value
        case (.none, .none): nil
        }
    }
}
