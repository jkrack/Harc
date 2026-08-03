import CryptoKit
import Foundation
import HarcDomain
import HarcHost
import HarcHostTransport
import HarcIdentity
import HarcProtocol
import HarcProtocolWire
import HarcTransfer
import Testing

@Suite("Host transport protocol adapter parity")
struct ProtocolAdapterParityTests {
    @Test("the production pairing adapter verifies the frozen proof and SAS")
    func pairingProofAndSAS() throws {
        let adapter = try authenticationAdapter()
        let hostKey = SoftwareP256SigningKey()
        let deviceKey = SoftwareP256SigningKey()
        let otherDeviceKey = SoftwareP256SigningKey()
        let ticketID = UUID()
        let claimID = UUID()
        let libraryID = LibraryID.random()
        let secret = bytes(0x11, count: 24)
        let secretBinding = try adapter.pairingTicketSecretBindingSHA256(
            ticketID: ticketID,
            secret: secret
        )
        let scopes = ScopePolicy.minimalScopes(for: .mobile)
        let transcript = try PairingTranscriptV1(
            ticketID: ticketID,
            claimID: claimID,
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            hostAuthorityPublicKey: hostKey.publicKey,
            tlsSPKISHA256: bytes(0x22),
            deviceID: deviceKey.publicKey.deviceID,
            devicePublicKey: deviceKey.publicKey,
            clientNonce: bytes(0x33),
            hostNonce: bytes(0x44),
            ticketSecretBindingSHA256: secretBinding,
            requestedScopes: scopes
        )
        let signature = try transcript.signClientProof(using: deviceKey)
        let input = HostPairingProofValidationInput(
            protocolMajor: 1,
            protocolMinor: 0,
            ticketID: ticketID,
            claimID: claimID,
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            hostAuthorityPublicKey: hostKey.publicKey,
            tlsSPKISHA256: bytes(0x22),
            deviceID: deviceKey.publicKey.deviceID,
            devicePublicKey: deviceKey.publicKey,
            clientNonce: bytes(0x33),
            hostNonce: bytes(0x44),
            ticketSecretBindingSHA256: secretBinding,
            requestedScopes: scopes,
            clientSignature: signature
        )

        let result = try adapter.validatePairingProofAndDeriveSAS(input)
        let expected = try HarcSASDictionaryV1.bundled().phrase(
            for: transcript,
            clientSignature: signature
        )

        #expect(result.sasDigest == expected.digest)
        #expect(result.sasWordIndexes == expected.indexes.map(UInt16.init))
        #expect(result.sasWords == expected.words)

        let wrongSignature = try otherDeviceKey.sign(
            digest: transcript.clientProofDigest()
        )
        let rejected = HostPairingProofValidationInput(
            protocolMajor: input.protocolMajor,
            protocolMinor: input.protocolMinor,
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
            requestedScopes: input.requestedScopes,
            clientSignature: wrongSignature
        )
        #expect(throws: HarcProtocolCodecError.invalidSignature) {
            try adapter.validatePairingProofAndDeriveSAS(rejected)
        }
    }

    @Test("the production session adapter binds exact capabilities and proof")
    func sessionCapabilitiesAndProof() throws {
        let adapter = try authenticationAdapter()
        let capabilities = try exactNegotiatedCapabilities()

        let validated = try adapter.validateNegotiatedCapabilities(
            exactBytes: capabilities.bytes,
            expectedSHA256: capabilities.sha256,
            protocolMajor: 1,
            protocolMinor: 0
        )
        #expect(validated.exactBytes == capabilities.bytes)
        #expect(validated.sha256 == capabilities.sha256)
        #expect(validated.selectedCodec == "raw-pcm-s16le-fixture")
        #expect(validated.selectedContainer == "raw-pcm-fixture")

        var wrongHash = capabilities.sha256
        wrongHash[0] ^= 0xff
        #expect(throws: HarcProtobufConversionError.exactPayloadHashMismatch) {
            try adapter.validateNegotiatedCapabilities(
                exactBytes: capabilities.bytes,
                expectedSHA256: wrongHash,
                protocolMajor: 1,
                protocolMinor: 0
            )
        }
        #expect(throws: HarcProtocolCodecError.unsupportedProtocolMajor(2)) {
            try adapter.validateProtocolVersion(major: 2, minor: 0)
        }

        let hostKey = SoftwareP256SigningKey()
        let deviceKey = SoftwareP256SigningKey()
        let otherDeviceKey = SoftwareP256SigningKey()
        let libraryID = LibraryID.random()
        let grantID = GrantID.random()
        let grantEpoch = try GrantEpoch(7)
        let challengeID = UUID()
        let transcript = try SessionTranscriptV1(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            tlsSPKISHA256: bytes(0x51),
            deviceID: deviceKey.publicKey.deviceID,
            grantID: grantID.rawValue,
            grantEpoch: grantEpoch.rawValue,
            challengeID: challengeID,
            serverNonce: bytes(0x52),
            clientNonce: bytes(0x53),
            capabilitiesSHA256: capabilities.sha256
        )
        let signature = try transcript.signClientProof(using: deviceKey)
        let input = HostSessionProofValidationInput(
            protocolMajor: 1,
            protocolMinor: 0,
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            tlsSPKISHA256: bytes(0x51),
            deviceID: deviceKey.publicKey.deviceID,
            devicePublicKey: deviceKey.publicKey,
            grantID: grantID,
            grantEpoch: grantEpoch,
            challengeID: challengeID,
            serverNonce: bytes(0x52),
            clientNonce: bytes(0x53),
            capabilitiesSHA256: capabilities.sha256,
            clientSignature: signature
        )
        try adapter.validateSessionProof(input)

        let wrongSignature = try otherDeviceKey.sign(
            digest: transcript.clientProofDigest()
        )
        let rejected = HostSessionProofValidationInput(
            protocolMajor: input.protocolMajor,
            protocolMinor: input.protocolMinor,
            libraryID: input.libraryID,
            hostAuthorityID: input.hostAuthorityID,
            tlsSPKISHA256: input.tlsSPKISHA256,
            deviceID: input.deviceID,
            devicePublicKey: input.devicePublicKey,
            grantID: input.grantID,
            grantEpoch: input.grantEpoch,
            challengeID: input.challengeID,
            serverNonce: input.serverNonce,
            clientNonce: input.clientNonce,
            capabilitiesSHA256: input.capabilitiesSHA256,
            clientSignature: wrongSignature
        )
        #expect(throws: HarcProtocolCodecError.invalidSignature) {
            try adapter.validateSessionProof(rejected)
        }
    }

    @Test("the production transport-set adapter preserves exact authenticated bytes")
    func transportSetIssueAndDecode() throws {
        let adapter = HarcHostTransportSetProtocolAdapterV1()
        let hostKey = SoftwareP256SigningKey()
        let libraryID = LibraryID.random()
        let issuedAt: UInt64 = 1_800_000_000_000
        let entry = try HostValidatedTransportSetEntry(
            tlsSPKISHA256: bytes(0x61),
            notBeforeUnixMilliseconds: issuedAt - 1_000,
            notAfterUnixMilliseconds: issuedAt + 60_000
        )
        let issued = try adapter.issueTransportSet(
            HostTransportSetIssueRequest(
                libraryID: libraryID,
                hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                setEpoch: 4,
                issuedAtUnixMilliseconds: issuedAt,
                entries: [entry],
                hostAuthoritySigner: hostKey
            )
        )
        let decoded = try adapter.decodeTransportSet(
            HostTransportSetDecodeRequest(
                exactSignedBytes: issued.exactSignedBytes,
                hostAuthorityPublicKey: hostKey.publicKey
            )
        )

        #expect(decoded == issued)
        #expect(decoded.libraryID == libraryID)
        #expect(decoded.setEpoch == 4)
        #expect(decoded.entries == [entry])

        var tampered = issued.exactSignedBytes
        tampered[tampered.count - 1] ^= 0x01
        #expect(throws: HarcProtocolCodecError.invalidSignature) {
            try adapter.decodeTransportSet(
                HostTransportSetDecodeRequest(
                    exactSignedBytes: tampered,
                    hostAuthorityPublicKey: hostKey.publicKey
                )
            )
        }

        let otherKey = SoftwareP256SigningKey()
        #expect(throws: HarcProtocolCodecError.invalidKeyBinding(
            field: "hostAuthorityID"
        )) {
            try adapter.decodeTransportSet(
                HostTransportSetDecodeRequest(
                    exactSignedBytes: issued.exactSignedBytes,
                    hostAuthorityPublicKey: otherKey.publicKey
                )
            )
        }
    }

    @Test("the production transport-set adapter rejects noncanonical issuance")
    func transportSetCanonicalOrder() throws {
        let adapter = HarcHostTransportSetProtocolAdapterV1()
        let hostKey = SoftwareP256SigningKey()
        let issuedAt: UInt64 = 1_800_000_000_000
        let earlier = try HostValidatedTransportSetEntry(
            tlsSPKISHA256: bytes(0x71),
            notBeforeUnixMilliseconds: issuedAt - 1_000,
            notAfterUnixMilliseconds: issuedAt + 60_000
        )
        let later = try HostValidatedTransportSetEntry(
            tlsSPKISHA256: bytes(0x72),
            notBeforeUnixMilliseconds: issuedAt - 1_000,
            notAfterUnixMilliseconds: issuedAt + 60_000
        )

        #expect(throws: HarcProtocolCodecError.nonCanonicalOrder(
            field: "transportEntries"
        )) {
            try adapter.issueTransportSet(
                HostTransportSetIssueRequest(
                    libraryID: .random(),
                    hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                    setEpoch: 1,
                    issuedAtUnixMilliseconds: issuedAt,
                    entries: [later, earlier],
                    hostAuthoritySigner: hostKey
                )
            )
        }
    }

    private func authenticationAdapter() throws
        -> HarcHostAuthenticationProtocolAdapterV1
    {
        try HarcHostAuthenticationProtocolAdapterV1(
            capabilityPolicy: HarcCapabilityPolicyV1(
                compatibility: HarcProtobufCompatibilityPolicy(
                    versionPolicy: .currentV1,
                    supportedRequiredFeatures: ["transfer.chunk.v1"]
                ),
                supportedFeatureIDs: ["transfer.chunk.v1"],
                supportedDescriptorSchemaIDs: ["harc.chunk-descriptor.v1"],
                supportedEncodings: [.rawPCMFixture],
                allowRawPCMFixture: true
            )
        )
    }

    private func exactNegotiatedCapabilities() throws
        -> (bytes: Data, sha256: Data)
    {
        var value = Harc_V1_NegotiatedCapabilitiesV1()
        value.protocol.major = 1
        value.protocol.minor = 0
        value.protocol.requirements.requiredFeatures = ["transfer.chunk.v1"]
        value.selectedFeatureIds = ["transfer.chunk.v1"]
        value.descriptorSchemaID = "harc.chunk-descriptor.v1"
        value.encoding = Harc_V1_LosslessEncodingConfigurationV1(.rawPCMFixture)
        value.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        let exactBytes = try value.serializedData()
        return (exactBytes, Data(SHA256.hash(data: exactBytes)))
    }

    private func bytes(_ byte: UInt8, count: Int = 32) -> Data {
        Data(repeating: byte, count: count)
    }
}
