import Foundation

/// Protocol-specific compatibility, canonical encoding, and deterministic
/// selection remain in HarcHostTransport. HarcHost receives only validated
/// semantic projections plus the exact negotiated payload that sessions bind.
public protocol HostInfoProtocolBoundary: Sendable {
    func validateProtocolVersion(major: UInt16, minor: UInt16) throws

    func advertisedCapabilityOffers() throws -> [HostInfoCapabilityOffer]

    func negotiateCapabilities(
        protocolMajor: UInt16,
        protocolMinor: UInt16,
        clientOffer: HostInfoCapabilityOffer
    ) throws -> HostNegotiatedSessionCapabilities
}
