import Foundation
import HarcDomain
import HarcIdentity

public enum HarcSignedObjectSignerClassV1: Equatable, Hashable, Sendable {
    case hostAuthority
    case device
}

public struct HarcSignedPayloadBindingsV1: Equatable, Hashable, Sendable {
    public let protocolVersion: HarcProtocolVersion
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let issuedAtUnixMilliseconds: UInt64
    public let signerDeviceID: DeviceID?
    public let grantID: UUID?
    public let grantEpoch: UInt64?
    public let operationID: UUID?
    public let expiresAtUnixMilliseconds: UInt64?
    public let expectedRevision: UInt64?

    public init(
        protocolVersion: HarcProtocolVersion,
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        issuedAtUnixMilliseconds: UInt64,
        signerDeviceID: DeviceID? = nil,
        grantID: UUID? = nil,
        grantEpoch: UInt64? = nil,
        operationID: UUID? = nil,
        expiresAtUnixMilliseconds: UInt64? = nil,
        expectedRevision: UInt64? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        self.issuedAtUnixMilliseconds = issuedAtUnixMilliseconds
        self.signerDeviceID = signerDeviceID
        self.grantID = grantID
        self.grantEpoch = grantEpoch
        self.operationID = operationID
        self.expiresAtUnixMilliseconds = expiresAtUnixMilliseconds
        self.expectedRevision = expectedRevision
    }
}

public struct HarcCurrentGrantBindingV1: Equatable, Hashable, Sendable {
    /// A complete, current server-side authorization snapshot. Keeping the
    /// registry entry intact prevents command acceptance from accidentally
    /// projecting live authority down to only a grant UUID and epoch.
    package let registryEntry: DeviceRegistryEntry

    /// Only package adapters that have just loaded the authoritative registry
    /// row may construct this value. The command verifier rechecks every
    /// identity, key, scope, status, and lifetime binding at acceptance time.
    package init(registryEntry: DeviceRegistryEntry) throws {
        guard registryEntry.status == .active,
              registryEntry.revocation == nil,
              registryEntry.currentGrantID.rawValue != HarcSignedEnvelopeV1.zeroUUID,
              registryEntry.currentGrantEpoch.rawValue > 0 else {
            throw HarcProtocolCodecError.staleGrant
        }
        self.registryEntry = registryEntry
    }
}

public struct HarcRegisteredSignedObjectV1: Equatable, Hashable, Sendable {
    public let messageType: HarcSignedMessageTypeV1
    public let payloadType: HarcSignedPayloadTypeV1
    public let signerClass: HarcSignedObjectSignerClassV1

    private let grantRule: MirrorRule
    private let operationRule: MirrorRule
    private let expiryRule: ExpiryRule
    private let revisionRule: MirrorRule

    public static let all: [Self] = [
        Self(.hostTransportSet, .hostTransportSet, .hostAuthority, .zero, .zero, .none, .zero),
        Self(.deviceGrant, .deviceGrant, .hostAuthority, .mirror, .zero, .mirrorOptional, .zero),
        Self(.deviceRevocation, .deviceRevocation, .hostAuthority, .mirror, .mirror, .none, .zero),
        Self(.recordingManifest, .recordingManifest, .device, .zero, .mirror, .none, .zero),
        Self(.batchAcknowledgement, .batchAcknowledgement, .hostAuthority, .zero, .mirror, .none, .zero),
        Self(.recordingReceipt, .recordingReceipt, .hostAuthority, .zero, .mirror, .none, .zero),
        Self(.metadataMutation, .metadataMutation, .device, .mirror, .mirror, .command, .mirror),
        Self(.processingArtifact, .processingArtifact, .device, .mirror, .mirror, .command, .zero),
        Self(.portableTrustHistory, .portableTrustHistory, .hostAuthority, .zero, .mirror, .none, .zero),
    ]

    public static func registered(
        messageType: HarcSignedMessageTypeV1,
        payloadType: HarcSignedPayloadTypeV1
    ) throws -> Self {
        guard let value = all.first(where: {
            $0.messageType == messageType && $0.payloadType == payloadType
        }) else {
            throw HarcProtocolCodecError.unregisteredSignedObject(
                messageType: messageType.rawValue,
                payloadType: payloadType.rawValue
            )
        }
        return value
    }

    /// Performs the registry checks that do not require interpreting protobuf
    /// payload bytes. Both signing and framed-object decoding call this gate;
    /// payload mirroring remains the explicit second validation stage below.
    public static func validateHeaderAdmission(_ header: HarcSignedEnvelopeV1) throws {
        let registration = try registered(
            messageType: header.messageType,
            payloadType: header.payloadType
        )
        try registration.validateHeaderStructure(header)
    }

    public func validateHeaderStructure(_ header: HarcSignedEnvelopeV1) throws {
        guard header.messageType == messageType, header.payloadType == payloadType else {
            throw HarcProtocolCodecError.unregisteredSignedObject(
                messageType: header.messageType.rawValue,
                payloadType: header.payloadType.rawValue
            )
        }

        switch signerClass {
        case .hostAuthority:
            guard header.signerDeviceID == nil else {
                throw HarcProtocolCodecError.wrongSignerClass
            }
        case .device:
            guard let deviceID = header.signerDeviceID,
                  !deviceID.rawBytes.allSatisfy({ $0 == 0 }) else {
                throw HarcProtocolCodecError.wrongSignerClass
            }
        }

        switch grantRule {
        case .zero:
            guard header.grantID == nil, header.grantEpoch == 0 else {
                throw HarcProtocolCodecError.headerPayloadMismatch(field: "grant")
            }
        case .mirror:
            guard let grantID = header.grantID,
                  grantID != HarcSignedEnvelopeV1.zeroUUID,
                  header.grantEpoch > 0 else {
                throw HarcProtocolCodecError.headerPayloadMismatch(field: "grant")
            }
        }

        switch operationRule {
        case .zero:
            guard header.operationID == nil else {
                throw HarcProtocolCodecError.headerPayloadMismatch(field: "operationID")
            }
        case .mirror:
            guard let operationID = header.operationID,
                  operationID != HarcSignedEnvelopeV1.zeroUUID else {
                throw HarcProtocolCodecError.headerPayloadMismatch(field: "operationID")
            }
        }

        switch expiryRule {
        case .none:
            guard header.expiresAtUnixMilliseconds == nil else {
                throw HarcProtocolCodecError.headerPayloadMismatch(field: "expiresAtUnixMilliseconds")
            }
        case .mirrorOptional:
            if let expiry = header.expiresAtUnixMilliseconds,
               expiry <= header.issuedAtUnixMilliseconds {
                throw HarcProtocolCodecError.invalidTimeRange(field: "expiresAtUnixMilliseconds")
            }
        case .command:
            guard let expiry = header.expiresAtUnixMilliseconds,
                  expiry > header.issuedAtUnixMilliseconds else {
                throw HarcProtocolCodecError.invalidTimeRange(field: "commandExpiry")
            }
            let maximum = try harcAdding(
                header.issuedAtUnixMilliseconds,
                HarcProtocolLimits.initialCommandLifetimeMilliseconds,
                field: "commandLifetime"
            )
            guard expiry <= maximum else {
                throw HarcProtocolCodecError.commandLifetimeExceeded
            }
        }

        switch revisionRule {
        case .zero:
            guard header.expectedRevision == nil else {
                throw HarcProtocolCodecError.headerPayloadMismatch(field: "expectedRevision")
            }
        case .mirror:
            guard header.expectedRevision != nil else {
                throw HarcProtocolCodecError.headerPayloadMismatch(field: "expectedRevision")
            }
        }
    }

    public func validateTuple(
        header: HarcSignedEnvelopeV1,
        payload: HarcSignedPayloadBindingsV1
    ) throws {
        try validateHeaderStructure(header)
        guard header.messageType == messageType, header.payloadType == payloadType else {
            throw HarcProtocolCodecError.unregisteredSignedObject(
                messageType: header.messageType.rawValue,
                payloadType: header.payloadType.rawValue
            )
        }
        try requireEqual(header.protocolVersion, payload.protocolVersion, field: "protocolVersion")
        try requireEqual(header.libraryID, payload.libraryID, field: "libraryID")
        try requireEqual(header.hostAuthorityID, payload.hostAuthorityID, field: "hostAuthorityID")
        try requireEqual(
            header.issuedAtUnixMilliseconds,
            payload.issuedAtUnixMilliseconds,
            field: "issuedAtUnixMilliseconds"
        )

        switch signerClass {
        case .hostAuthority:
            guard header.signerDeviceID == nil, payload.signerDeviceID == nil else {
                throw HarcProtocolCodecError.wrongSignerClass
            }
        case .device:
            guard let headerDevice = header.signerDeviceID,
                  let payloadDevice = payload.signerDeviceID,
                  headerDevice == payloadDevice else {
                throw HarcProtocolCodecError.wrongSignerClass
            }
        }

        switch grantRule {
        case .zero:
            guard header.grantID == nil, header.grantEpoch == 0,
                  payload.grantID == nil, payload.grantEpoch == nil else {
                throw HarcProtocolCodecError.headerPayloadMismatch(field: "grant")
            }
        case .mirror:
            guard let payloadGrantID = payload.grantID,
                  let payloadGrantEpoch = payload.grantEpoch,
                  payloadGrantID != HarcSignedEnvelopeV1.zeroUUID,
                  payloadGrantEpoch > 0 else {
                throw HarcProtocolCodecError.missingPayloadBinding(field: "grant")
            }
            try requireEqual(header.grantID, payloadGrantID, field: "grantID")
            try requireEqual(header.grantEpoch, payloadGrantEpoch, field: "grantEpoch")
        }

        switch operationRule {
        case .zero:
            guard header.operationID == nil, payload.operationID == nil else {
                throw HarcProtocolCodecError.headerPayloadMismatch(field: "operationID")
            }
        case .mirror:
            guard let payloadOperationID = payload.operationID,
                  payloadOperationID != HarcSignedEnvelopeV1.zeroUUID else {
                throw HarcProtocolCodecError.missingPayloadBinding(field: "operationID")
            }
            try requireEqual(header.operationID, payloadOperationID, field: "operationID")
        }

        switch expiryRule {
        case .none:
            guard header.expiresAtUnixMilliseconds == nil,
                  payload.expiresAtUnixMilliseconds == nil else {
                throw HarcProtocolCodecError.headerPayloadMismatch(field: "expiresAtUnixMilliseconds")
            }
        case .mirrorOptional:
            try requireEqual(
                header.expiresAtUnixMilliseconds,
                payload.expiresAtUnixMilliseconds,
                field: "expiresAtUnixMilliseconds"
            )
        case .command:
            guard let expiry = payload.expiresAtUnixMilliseconds else {
                throw HarcProtocolCodecError.missingPayloadBinding(field: "expiresAtUnixMilliseconds")
            }
            try requireEqual(header.expiresAtUnixMilliseconds, expiry, field: "expiresAtUnixMilliseconds")
            guard expiry > header.issuedAtUnixMilliseconds else {
                throw HarcProtocolCodecError.invalidTimeRange(field: "commandExpiry")
            }
            let maximum = try harcAdding(
                header.issuedAtUnixMilliseconds,
                HarcProtocolLimits.initialCommandLifetimeMilliseconds,
                field: "commandLifetime"
            )
            guard expiry <= maximum else {
                throw HarcProtocolCodecError.commandLifetimeExceeded
            }
        }

        switch revisionRule {
        case .zero:
            guard header.expectedRevision == nil, payload.expectedRevision == nil else {
                throw HarcProtocolCodecError.headerPayloadMismatch(field: "expectedRevision")
            }
        case .mirror:
            guard let revision = payload.expectedRevision else {
                throw HarcProtocolCodecError.missingPayloadBinding(field: "expectedRevision")
            }
            try requireEqual(header.expectedRevision, revision, field: "expectedRevision")
        }
    }

    public func validateInitialAcceptance(
        header: HarcSignedEnvelopeV1,
        atUnixMilliseconds acceptedAt: UInt64,
        currentGrant: HarcCurrentGrantBindingV1?,
        using signingPublicKey: P256X963PublicKey
    ) throws {
        guard expiryRule == .command else { return }
        let maximumFutureIssue = acceptedAt.addingReportingOverflow(
            HarcProtocolLimits.clientFutureSkewMilliseconds
        )
        let futureLimit = maximumFutureIssue.overflow ? UInt64.max : maximumFutureIssue.partialValue
        guard header.issuedAtUnixMilliseconds <= futureLimit else {
            throw HarcProtocolCodecError.invalidTimeRange(field: "issuedAtUnixMilliseconds")
        }
        guard let expiry = header.expiresAtUnixMilliseconds, acceptedAt < expiry else {
            throw HarcProtocolCodecError.commandExpired
        }
        guard let currentGrant else {
            throw HarcProtocolCodecError.currentGrantRequired
        }
        let entry = currentGrant.registryEntry
        guard entry.status == .active,
              entry.revocation == nil,
              entry.protocolVersion.major == header.protocolVersion.major,
              entry.protocolVersion.minor == header.protocolVersion.minor,
              entry.libraryID == header.libraryID,
              entry.hostAuthorityID == header.hostAuthorityID,
              entry.deviceID == header.signerDeviceID,
              entry.devicePublicKey == signingPublicKey,
              entry.devicePublicKey.deviceID == entry.deviceID,
              header.grantID == entry.currentGrantID.rawValue,
              header.grantEpoch == entry.currentGrantEpoch.rawValue,
              let requiredScope = requiredCommandScope,
              entry.currentScopes.contains(requiredScope) else {
            throw HarcProtocolCodecError.staleGrant
        }

        let commandIssuedAt = try harcDateFromUnixMilliseconds(
            header.issuedAtUnixMilliseconds,
            field: "issuedAtUnixMilliseconds"
        )
        let acceptedAtDate = try harcDateFromUnixMilliseconds(
            acceptedAt,
            field: "acceptedAtUnixMilliseconds"
        )
        guard commandIssuedAt >= entry.grantIssuedAt,
              acceptedAtDate >= entry.grantIssuedAt else {
            throw HarcProtocolCodecError.staleGrant
        }
        if let grantExpiresAt = entry.grantExpiresAt,
           commandIssuedAt >= grantExpiresAt || acceptedAtDate >= grantExpiresAt {
            throw HarcProtocolCodecError.commandExpired
        }
    }

    private var requiredCommandScope: AuthorizationScope? {
        switch messageType {
        case .metadataMutation: .libraryMetadataWrite
        case .processingArtifact: .processingSubmitOwn
        default: nil
        }
    }

    private init(
        _ messageType: HarcSignedMessageTypeV1,
        _ payloadType: HarcSignedPayloadTypeV1,
        _ signerClass: HarcSignedObjectSignerClassV1,
        _ grantRule: MirrorRule,
        _ operationRule: MirrorRule,
        _ expiryRule: ExpiryRule,
        _ revisionRule: MirrorRule
    ) {
        self.messageType = messageType
        self.payloadType = payloadType
        self.signerClass = signerClass
        self.grantRule = grantRule
        self.operationRule = operationRule
        self.expiryRule = expiryRule
        self.revisionRule = revisionRule
    }

    private enum MirrorRule: Equatable, Hashable, Sendable { case zero, mirror }
    private enum ExpiryRule: Equatable, Hashable, Sendable { case none, mirrorOptional, command }
}

public extension HarcSignedObjectV1 {
    package static func signRegistered(
        header: HarcSignedEnvelopeV1,
        exactPayloadBytes: Data,
        payloadBindings: HarcSignedPayloadBindingsV1,
        using signer: any P256DigestSigner
    ) throws -> Self {
        let registration = try HarcRegisteredSignedObjectV1.registered(
            messageType: header.messageType,
            payloadType: header.payloadType
        )
        try registration.validateTuple(header: header, payload: payloadBindings)
        return try sign(
            header: header,
            exactPayloadBytes: exactPayloadBytes,
            using: signer
        )
    }

    package func verifyRegistered(
        using publicKey: P256X963PublicKey,
        payloadBindings: HarcSignedPayloadBindingsV1,
        acceptedAtUnixMilliseconds: UInt64? = nil,
        currentGrant: HarcCurrentGrantBindingV1? = nil
    ) throws {
        let registration = try HarcRegisteredSignedObjectV1.registered(
            messageType: header.messageType,
            payloadType: header.payloadType
        )
        try registration.validateTuple(header: header, payload: payloadBindings)
        if let acceptedAtUnixMilliseconds {
            try registration.validateInitialAcceptance(
                header: header,
                atUnixMilliseconds: acceptedAtUnixMilliseconds,
                currentGrant: currentGrant,
                using: publicKey
            )
        }
        try verifySignature(using: publicKey)
    }
}

private func requireEqual<T: Equatable>(_ lhs: T, _ rhs: T, field: String) throws {
    guard lhs == rhs else { throw HarcProtocolCodecError.headerPayloadMismatch(field: field) }
}
