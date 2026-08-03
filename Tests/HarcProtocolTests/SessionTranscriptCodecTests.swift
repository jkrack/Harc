import CryptoKit
import Foundation
import HarcDomain
@testable import HarcIdentity
@testable import HarcProtocol
import Testing

@Suite("Session transcript codec")
struct SessionTranscriptCodecTests {
    @Test("session transcript has the frozen layout and exact proof digest")
    func roundTripAndProof() throws {
        let hostKey = ProtocolCodecFixtures.key(30)
        let deviceKey = ProtocolCodecFixtures.key(31)
        let transcript = try SessionTranscriptV1(
            libraryID: LibraryID(ProtocolCodecFixtures.uuid(300)),
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            tlsSPKISHA256: ProtocolCodecFixtures.bytes(0x51),
            deviceID: deviceKey.publicKey.deviceID,
            grantID: ProtocolCodecFixtures.uuid(301),
            grantEpoch: 9,
            challengeID: ProtocolCodecFixtures.uuid(302),
            serverNonce: ProtocolCodecFixtures.bytes(0x52),
            clientNonce: ProtocolCodecFixtures.bytes(0x53),
            capabilitiesSHA256: ProtocolCodecFixtures.bytes(0x54)
        )
        let bytes = transcript.encoded()
        let decoded = try SessionTranscriptV1.decode(bytes)
        let signature = try transcript.signClientProof(using: deviceKey)


        #expect(bytes.prefix(13) == Data("HARCSESSION1\0".utf8))
        #expect(bytes.count == 265)
        #expect(decoded == transcript)
        #expect(decoded.encoded() == bytes)
        #expect(transcript.clientProofDigest().rawBytes == Data(SHA256.hash(
            data: Data("HARC-SESSION-CLIENT-PROOF-V1\0".utf8) + bytes
        )))
        try decoded.verifyClientProof(signature, using: deviceKey.publicKey)
    }

    @Test("session key, grant, challenge, version, and exact length fail closed")
    func rejectionCases() throws {
        let hostKey = ProtocolCodecFixtures.key(32)
        let deviceKey = ProtocolCodecFixtures.key(33)
        let otherDevice = ProtocolCodecFixtures.key(34)
        let transcript = try SessionTranscriptV1(
            libraryID: LibraryID(ProtocolCodecFixtures.uuid(310)),
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            tlsSPKISHA256: ProtocolCodecFixtures.bytes(1),
            deviceID: deviceKey.publicKey.deviceID,
            grantID: ProtocolCodecFixtures.uuid(311),
            grantEpoch: 1,
            challengeID: ProtocolCodecFixtures.uuid(312),
            serverNonce: ProtocolCodecFixtures.bytes(2),
            clientNonce: ProtocolCodecFixtures.bytes(3),
            capabilitiesSHA256: ProtocolCodecFixtures.bytes(4)
        )
        let signature = try transcript.signClientProof(using: deviceKey)

        #expect(throws: HarcProtocolCodecError.invalidKeyBinding(field: "deviceID")) {
            try transcript.verifyClientProof(signature, using: otherDevice.publicKey)
        }
        #expect(throws: HarcProtocolCodecError.headerPayloadMismatch(field: "grant")) {
            try SessionTranscriptV1(
                libraryID: transcript.libraryID,
                hostAuthorityID: transcript.hostAuthorityID,
                tlsSPKISHA256: transcript.tlsSPKISHA256,
                deviceID: transcript.deviceID,
                grantID: HarcSignedEnvelopeV1.zeroUUID,
                grantEpoch: 0,
                challengeID: transcript.challengeID,
                serverNonce: transcript.serverNonce,
                clientNonce: transcript.clientNonce,
                capabilitiesSHA256: transcript.capabilitiesSHA256
            )
        }

        var trailing = transcript.encoded()
        trailing.append(0)
        #expect(throws: HarcProtocolCodecError.inputTooLarge(
            field: "SessionTranscriptV1",
            limit: UInt64(HarcProtocolLimits.sessionTranscriptBytes),
            actual: UInt64(HarcProtocolLimits.sessionTranscriptBytes + 1)
        )) {
            try SessionTranscriptV1.decode(trailing)
        }

        var unsupportedMinor = transcript.encoded()
        unsupportedMinor[16] = 1
        #expect(throws: HarcProtocolCodecError.unsupportedProtocolMinor(1)) {
            try SessionTranscriptV1.decode(unsupportedMinor)
        }
    }
}
