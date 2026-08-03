import Foundation
import HarcDomain
import HarcIdentity
import HarcProtocolWire

/// Public host-info requests are still decoded through the same fail-closed
/// compatibility boundary as authenticated calls. They authorize no state.
public struct HarcValidatedGetHostInfoRequestV1: Sendable {
    public let protocolVersion: HarcProtocolVersion

    public init(
        _ value: Harc_V1_GetHostInfoRequestV1,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        guard value.hasProtocol else {
            throw HarcProtobufConversionError.missingField("getHostInfo.protocol")
        }
        let (protocolVersion, _) = try compatibility.validate(
            value.protocol,
            knownCriticalFieldNumbers: [1]
        )
        self.protocolVersion = protocolVersion
    }
}

public struct HarcValidatedNegotiateCapabilitiesRequestV1: Sendable {
    public let protocolVersion: HarcProtocolVersion
    public let clientOffer: HarcValidatedCapabilityOfferV1

    public init(
        _ value: Harc_V1_NegotiateCapabilitiesRequestV1,
        policy: HarcCapabilityPolicyV1
    ) throws {
        guard value.hasProtocol else {
            throw HarcProtobufConversionError.missingField(
                "negotiateCapabilities.protocol"
            )
        }
        let (protocolVersion, _) = try policy.compatibility.validate(
            value.protocol,
            knownCriticalFieldNumbers: Set(1 ... 2)
        )
        guard value.hasClientOffer else {
            throw HarcProtobufConversionError.missingField(
                "negotiateCapabilities.clientOffer"
            )
        }
        let clientOffer = try HarcValidatedCapabilityOfferV1(
            value.clientOffer,
            policy: policy
        )
        guard clientOffer.protocolMajor == protocolVersion.major,
              clientOffer.minimumProtocolMinor <= protocolVersion.minor,
              protocolVersion.minor <= clientOffer.maximumProtocolMinor else {
            throw HarcProtobufConversionError.inconsistentField(
                "negotiateCapabilities.protocol"
            )
        }
        self.protocolVersion = protocolVersion
        self.clientOffer = clientOffer
    }
}

/// Validated semantic input for the only ticket-secret-bearing RPC. Transport
/// adapters construct this value before any Host application service is called;
/// raw protobuf values never become authorization facts directly.
public struct HarcValidatedBeginPairingClaimRequestV1: Sendable {
    public let protocolVersion: HarcProtocolVersion
    public let ticketID: UUID
    public let ticketSecret: Data
    public let clientNonce: Data
    public let devicePublicKey: P256X963PublicKey
    public let requestedScopes: [AuthorizationScope]
    public let deviceLabel: String

    public init(
        _ value: Harc_V1_BeginPairingClaimRequestV1,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        guard value.hasProtocol else {
            throw HarcProtobufConversionError.missingField("beginPairingClaim.protocol")
        }
        let (protocolVersion, _) = try compatibility.validate(
            value.protocol,
            knownCriticalFieldNumbers: Set(1 ... 7)
        )
        guard value.hasTicketID else {
            throw HarcProtobufConversionError.missingField("beginPairingClaim.ticketID")
        }
        try Self.requireLength(
            value.ticketSecret,
            expected: 24,
            field: "beginPairingClaim.ticketSecret"
        )
        try Self.requireLength(
            value.clientNonce,
            expected: 32,
            field: "beginPairingClaim.clientNonce"
        )

        let publicKey: P256X963PublicKey
        do {
            publicKey = try P256X963PublicKey(value.devicePublicKeyX963)
        } catch {
            throw HarcProtobufConversionError.invalidValue(
                field: "beginPairingClaim.devicePublicKeyX963"
            )
        }
        guard value.requestedScopes.count <= HarcProtocolLimits.pairingRequestedScopes else {
            throw HarcProtobufConversionError.invalidValue(
                field: "beginPairingClaim.requestedScopes"
            )
        }
        let scopes = try value.requestedScopes.map { try $0.domainValue() }
        let scopeNames = scopes.map(\.rawValue)
        guard scopeNames == scopeNames.sorted() else {
            throw HarcProtobufConversionError.nonCanonicalOrder(
                field: "beginPairingClaim.requestedScopes"
            )
        }
        guard Set(scopeNames).count == scopeNames.count else {
            throw HarcProtobufConversionError.duplicateValue(
                field: "beginPairingClaim.requestedScopes"
            )
        }
        try Self.validateDisplayLabel(value.deviceLabel)

        self.protocolVersion = protocolVersion
        self.ticketID = try value.ticketID.validatedUUID()
        self.ticketSecret = value.ticketSecret
        self.clientNonce = value.clientNonce
        self.devicePublicKey = publicKey
        self.requestedScopes = scopes
        self.deviceLabel = value.deviceLabel
    }
}

public struct HarcValidatedProvePairingClaimRequestV1: Sendable {
    public let protocolVersion: HarcProtocolVersion
    public let claimID: UUID
    public let clientSignature: P256RawSignature

    public init(
        _ value: Harc_V1_ProvePairingClaimRequestV1,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        guard value.hasProtocol else {
            throw HarcProtobufConversionError.missingField("provePairingClaim.protocol")
        }
        let (protocolVersion, _) = try compatibility.validate(
            value.protocol,
            knownCriticalFieldNumbers: Set(1 ... 3)
        )
        guard value.hasClaimID else {
            throw HarcProtobufConversionError.missingField("provePairingClaim.claimID")
        }
        let signature: P256RawSignature
        do {
            signature = try P256RawSignature(value.clientSignatureRaw)
        } catch {
            throw HarcProtobufConversionError.invalidValue(
                field: "provePairingClaim.clientSignatureRaw"
            )
        }
        self.protocolVersion = protocolVersion
        self.claimID = try value.claimID.validatedUUID()
        self.clientSignature = signature
    }
}

public struct HarcValidatedGetPairingStatusRequestV1: Sendable {
    public let protocolVersion: HarcProtocolVersion
    public let claimID: UUID

    public init(
        _ value: Harc_V1_GetPairingStatusRequestV1,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        guard value.hasProtocol else {
            throw HarcProtobufConversionError.missingField("getPairingStatus.protocol")
        }
        let (protocolVersion, _) = try compatibility.validate(
            value.protocol,
            knownCriticalFieldNumbers: Set(1 ... 2)
        )
        guard value.hasClaimID else {
            throw HarcProtobufConversionError.missingField("getPairingStatus.claimID")
        }
        self.protocolVersion = protocolVersion
        self.claimID = try value.claimID.validatedUUID()
    }
}

public struct HarcValidatedBeginSessionRequestV1: Sendable {
    public let protocolVersion: HarcProtocolVersion
    public let claimedDeviceID: DeviceID
    public let grantID: GrantID

    public init(
        _ value: Harc_V1_BeginSessionRequestV1,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        guard value.hasProtocol else {
            throw HarcProtobufConversionError.missingField("beginSession.protocol")
        }
        let (protocolVersion, _) = try compatibility.validate(
            value.protocol,
            knownCriticalFieldNumbers: Set(1 ... 3)
        )
        guard value.hasClaimedDeviceID else {
            throw HarcProtobufConversionError.missingField("beginSession.claimedDeviceID")
        }
        guard value.hasGrantID else {
            throw HarcProtobufConversionError.missingField("beginSession.grantID")
        }
        self.protocolVersion = protocolVersion
        self.claimedDeviceID = try value.claimedDeviceID.domainValue()
        self.grantID = try value.grantID.domainValue()
    }
}

/// OpenSession carries the exact capability payload because that byte string,
/// rather than a protobuf reserialization, is hashed into the session proof.
public struct HarcValidatedOpenSessionRequestV1: Sendable {
    public let protocolVersion: HarcProtocolVersion
    public let challengeID: UUID
    public let clientNonce: Data
    public let negotiatedCapabilities: HarcValidatedNegotiatedCapabilitiesV1
    public let clientSignature: P256RawSignature

    public init(
        _ value: Harc_V1_OpenSessionRequestV1,
        capabilityPolicy: HarcCapabilityPolicyV1
    ) throws {
        guard value.hasProtocol else {
            throw HarcProtobufConversionError.missingField("openSession.protocol")
        }
        let (protocolVersion, _) = try capabilityPolicy.compatibility.validate(
            value.protocol,
            knownCriticalFieldNumbers: Set(1 ... 6)
        )
        guard value.hasChallengeID else {
            throw HarcProtobufConversionError.missingField("openSession.challengeID")
        }
        try HarcValidatedBeginPairingClaimRequestV1.requireLength(
            value.clientNonce,
            expected: 32,
            field: "openSession.clientNonce"
        )
        guard value.hasNegotiatedCapabilitiesSha256 else {
            throw HarcProtobufConversionError.missingField(
                "openSession.negotiatedCapabilitiesSHA256"
            )
        }
        let capabilities = try HarcValidatedNegotiatedCapabilitiesV1(
            decoding: value.exactNegotiatedCapabilitiesPayload,
            expectedSHA256: try value.negotiatedCapabilitiesSha256.validatedBytes(
                field: "openSession.negotiatedCapabilitiesSHA256"
            ),
            policy: capabilityPolicy
        )
        guard capabilities.protocolVersion == protocolVersion else {
            throw HarcProtobufConversionError.inconsistentField(
                "openSession.negotiatedCapabilities.protocol"
            )
        }
        let signature: P256RawSignature
        do {
            signature = try P256RawSignature(value.clientSignatureRaw)
        } catch {
            throw HarcProtobufConversionError.invalidValue(
                field: "openSession.clientSignatureRaw"
            )
        }

        self.protocolVersion = protocolVersion
        self.challengeID = try value.challengeID.validatedUUID()
        self.clientNonce = value.clientNonce
        self.negotiatedCapabilities = capabilities
        self.clientSignature = signature
    }
}

fileprivate extension HarcValidatedBeginPairingClaimRequestV1 {
    static func requireLength(
        _ bytes: Data,
        expected: Int,
        field: String
    ) throws {
        guard bytes.count == expected else {
            throw HarcProtobufConversionError.invalidLength(
                field: field,
                expected: expected,
                actual: bytes.count
            )
        }
    }

    static func validateDisplayLabel(_ label: String) throws {
        let normalizedLabel = label.precomposedStringWithCanonicalMapping
        guard !label.isEmpty,
              label.utf8.count <= HarcProtocolLimits.pairingDeviceLabelBytes,
              label.utf8.elementsEqual(normalizedLabel.utf8),
              !label.unicodeScalars.contains(where: {
                  $0.value == 0 || CharacterSet.controlCharacters.contains($0)
              }) else {
            throw HarcProtobufConversionError.invalidValue(
                field: "beginPairingClaim.deviceLabel"
            )
        }
    }
}
