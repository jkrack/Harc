import Foundation
import HarcHost
import HarcProtocol

/// The sole authentication protocol composition adapter for frozen v1.
/// HarcHost remains independent of HarcProtocol's codecs and wire projections.
public struct HarcHostAuthenticationProtocolAdapterV1:
    HostAuthenticationProtocolBoundary
{
    private let capabilityPolicy: HarcCapabilityPolicyV1
    private let sasDictionary: HarcSASDictionaryV1

    public init(
        capabilityPolicy: HarcCapabilityPolicyV1,
        sasDictionary: HarcSASDictionaryV1? = nil
    ) throws {
        self.capabilityPolicy = capabilityPolicy
        self.sasDictionary = try sasDictionary ?? .bundled()
    }

    public func pairingTicketSecretBindingSHA256(
        ticketID: UUID,
        secret: Data
    ) throws -> Data {
        try PairingTicketV1.ticketSecretBindingSHA256(
            ticketID: ticketID,
            secret: secret
        )
    }

    public func validatePairingProofAndDeriveSAS(
        _ input: HostPairingProofValidationInput
    ) throws -> HostPairingProofResult {
        let transcript = try PairingTranscriptV1(
            protocolVersion: HarcProtocolVersion(
                major: input.protocolMajor,
                minor: input.protocolMinor
            ),
            ticketID: input.ticketID,
            claimID: input.claimID,
            libraryID: input.libraryID,
            hostAuthorityID: input.hostAuthorityID,
            hostAuthorityPublicKey: input.hostAuthorityPublicKey,
            tlsSPKISHA256: input.tlsSPKISHA256,
            deviceID: input.deviceID,
            devicePublicKey: input.devicePublicKey,
            clientNonce: input.clientNonce,
            hostNonce: input.hostNonce,
            ticketSecretBindingSHA256: input.ticketSecretBindingSHA256,
            requestedScopes: input.requestedScopes
        )
        try transcript.verifyClientProof(input.clientSignature)
        let phrase = try sasDictionary.phrase(
            for: transcript,
            clientSignature: input.clientSignature
        )
        return try HostPairingProofResult(
            sasDigest: phrase.digest,
            sasWordIndexes: phrase.indexes.map(UInt16.init),
            sasWords: phrase.words
        )
    }

    public func validateProtocolVersion(major: UInt16, minor: UInt16) throws {
        try capabilityPolicy.compatibility.versionPolicy.validate(
            HarcProtocolVersion(major: major, minor: minor)
        )
    }

    public func validateNegotiatedCapabilities(
        exactBytes: Data,
        expectedSHA256: Data,
        protocolMajor: UInt16,
        protocolMinor: UInt16
    ) throws -> HostNegotiatedSessionCapabilities {
        let validated = try HarcValidatedNegotiatedCapabilitiesV1(
            decoding: exactBytes,
            expectedSHA256: expectedSHA256,
            policy: capabilityPolicy
        )
        guard validated.protocolVersion.major == protocolMajor,
              validated.protocolVersion.minor == protocolMinor else {
            throw HarcProtocolCodecError.headerPayloadMismatch(
                field: "negotiatedCapabilities.protocol"
            )
        }
        return try HostNegotiatedSessionCapabilities(
            exactBytes: validated.exactPayload.exactBytes,
            sha256: validated.exactSHA256,
            protocolMajor: validated.protocolVersion.major,
            protocolMinor: validated.protocolVersion.minor,
            selectedCodec: validated.encoding.codec.rawValue,
            selectedContainer: validated.encoding.container.rawValue
        )
    }

    public func validateSessionProof(
        _ input: HostSessionProofValidationInput
    ) throws {
        let transcript = try SessionTranscriptV1(
            protocolVersion: HarcProtocolVersion(
                major: input.protocolMajor,
                minor: input.protocolMinor
            ),
            libraryID: input.libraryID,
            hostAuthorityID: input.hostAuthorityID,
            tlsSPKISHA256: input.tlsSPKISHA256,
            deviceID: input.deviceID,
            grantID: input.grantID.rawValue,
            grantEpoch: input.grantEpoch.rawValue,
            challengeID: input.challengeID,
            serverNonce: input.serverNonce,
            clientNonce: input.clientNonce,
            capabilitiesSHA256: input.capabilitiesSHA256
        )
        try transcript.verifyClientProof(
            input.clientSignature,
            using: input.devicePublicKey
        )
    }
}
