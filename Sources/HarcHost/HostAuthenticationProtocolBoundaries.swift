import Foundation
import HarcDomain
import HarcIdentity

/// Protocol-neutral input for the frozen pairing proof and SAS operation.
/// HarcHost owns the durable facts; a transport composition adapter owns their
/// exact protocol encoding and cryptographic transcript semantics.
public struct HostPairingProofValidationInput: Sendable {
    public let protocolMajor: UInt16
    public let protocolMinor: UInt16
    public let ticketID: UUID
    public let claimID: UUID
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let hostAuthorityPublicKey: P256X963PublicKey
    public let tlsSPKISHA256: Data
    public let deviceID: DeviceID
    public let devicePublicKey: P256X963PublicKey
    public let clientNonce: Data
    public let hostNonce: Data
    public let ticketSecretBindingSHA256: Data
    public let requestedScopes: [AuthorizationScope]
    public let clientSignature: P256RawSignature

    public init(
        protocolMajor: UInt16,
        protocolMinor: UInt16,
        ticketID: UUID,
        claimID: UUID,
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        hostAuthorityPublicKey: P256X963PublicKey,
        tlsSPKISHA256: Data,
        deviceID: DeviceID,
        devicePublicKey: P256X963PublicKey,
        clientNonce: Data,
        hostNonce: Data,
        ticketSecretBindingSHA256: Data,
        requestedScopes: [AuthorizationScope],
        clientSignature: P256RawSignature
    ) {
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.ticketID = ticketID
        self.claimID = claimID
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        self.hostAuthorityPublicKey = hostAuthorityPublicKey
        self.tlsSPKISHA256 = tlsSPKISHA256
        self.deviceID = deviceID
        self.devicePublicKey = devicePublicKey
        self.clientNonce = clientNonce
        self.hostNonce = hostNonce
        self.ticketSecretBindingSHA256 = ticketSecretBindingSHA256
        self.requestedScopes = requestedScopes
        self.clientSignature = clientSignature
    }
}

/// Protocol-neutral input for the frozen session proof operation.
public struct HostSessionProofValidationInput: Sendable {
    public let protocolMajor: UInt16
    public let protocolMinor: UInt16
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let tlsSPKISHA256: Data
    public let deviceID: DeviceID
    public let devicePublicKey: P256X963PublicKey
    public let grantID: GrantID
    public let grantEpoch: GrantEpoch
    public let challengeID: UUID
    public let serverNonce: Data
    public let clientNonce: Data
    public let capabilitiesSHA256: Data
    public let clientSignature: P256RawSignature

    public init(
        protocolMajor: UInt16,
        protocolMinor: UInt16,
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        tlsSPKISHA256: Data,
        deviceID: DeviceID,
        devicePublicKey: P256X963PublicKey,
        grantID: GrantID,
        grantEpoch: GrantEpoch,
        challengeID: UUID,
        serverNonce: Data,
        clientNonce: Data,
        capabilitiesSHA256: Data,
        clientSignature: P256RawSignature
    ) {
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        self.tlsSPKISHA256 = tlsSPKISHA256
        self.deviceID = deviceID
        self.devicePublicKey = devicePublicKey
        self.grantID = grantID
        self.grantEpoch = grantEpoch
        self.challengeID = challengeID
        self.serverNonce = serverNonce
        self.clientNonce = clientNonce
        self.capabilitiesSHA256 = capabilitiesSHA256
        self.clientSignature = clientSignature
    }
}

public protocol HostPairingTicketBindingBoundary: Sendable {
    func pairingTicketSecretBindingSHA256(
        ticketID: UUID,
        secret: Data
    ) throws -> Data
}

public protocol HostPairingProofValidatingBoundary: Sendable {
    func validatePairingProofAndDeriveSAS(
        _ input: HostPairingProofValidationInput
    ) throws -> HostPairingProofResult
}

public protocol HostNegotiatedCapabilitiesValidatingBoundary: Sendable {
    func validateProtocolVersion(major: UInt16, minor: UInt16) throws

    func validateNegotiatedCapabilities(
        exactBytes: Data,
        expectedSHA256: Data,
        protocolMajor: UInt16,
        protocolMinor: UInt16
    ) throws -> HostNegotiatedSessionCapabilities
}

public protocol HostSessionProofValidatingBoundary: Sendable {
    func validateSessionProof(
        _ input: HostSessionProofValidationInput
    ) throws
}

public protocol HostPairingAuthenticationProtocolBoundary:
    HostPairingTicketBindingBoundary,
    HostPairingProofValidatingBoundary
{}

public protocol HostSessionAuthenticationProtocolBoundary:
    HostNegotiatedCapabilitiesValidatingBoundary,
    HostSessionProofValidatingBoundary
{}

/// Full production composition surface. HarcHostTransport's v1 adapter is the
/// concrete implementation; focused HarcHost tests may inject explicit seams.
public protocol HostAuthenticationProtocolBoundary:
    HostPairingAuthenticationProtocolBoundary,
    HostSessionAuthenticationProtocolBoundary
{}
