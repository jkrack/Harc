import CryptoKit
import Foundation
import HarcDomain
@testable import HarcIdentity
@testable import HarcProtocol
import Testing

@Suite("Pairing transcript, proof, and SAS codec")
struct PairingTranscriptCodecTests {
    @Test("pairing transcript round-trips and proof is a single exact prehash")
    func transcriptAndProof() throws {
        let hostKey = ProtocolCodecFixtures.key(20)
        let deviceKey = ProtocolCodecFixtures.key(21)
        let transcript = try makeTranscript(hostKey: hostKey, deviceKey: deviceKey)
        let bytes = try transcript.encoded()
        let decoded = try PairingTranscriptV1.decode(bytes)
        let signature = try transcript.signClientProof(using: deviceKey)


        #expect(bytes.prefix(10) == Data("HARCPAIR1\0".utf8))
        #expect(bytes[10 ... 13] == Data([0, 1, 0, 0]))
        #expect(decoded == transcript)
        #expect(try decoded.encoded() == bytes)
        try decoded.verifyClientProof(signature)

        let expectedDigest = Data(SHA256.hash(
            data: Data("HARC-PAIRING-CLIENT-PROOF-V1\0".utf8) + bytes
        ))
        #expect(try transcript.clientProofDigest().rawBytes == expectedDigest)

        let unrelated = try deviceKey.sign(
            digest: P256SHA256Digest(hashing: Data("unrelated".utf8))
        )
        #expect(throws: HarcProtocolCodecError.invalidSignature) {
            try decoded.verifyClientProof(unrelated)
        }
    }

    @Test("pairing bindings, nonce sizes, scope registration, order, and uniqueness are strict")
    func pairingBindingRules() throws {
        let hostKey = ProtocolCodecFixtures.key(22)
        let otherHost = ProtocolCodecFixtures.key(23)
        let deviceKey = ProtocolCodecFixtures.key(24)
        let base = try makeTranscript(hostKey: hostKey, deviceKey: deviceKey)

        #expect(throws: HarcProtocolCodecError.invalidKeyBinding(field: "hostAuthorityID")) {
            try PairingTranscriptV1(
                ticketID: base.ticketID,
                claimID: base.claimID,
                libraryID: base.libraryID,
                hostAuthorityID: otherHost.publicKey.hostAuthorityID,
                hostAuthorityPublicKey: hostKey.publicKey,
                tlsSPKISHA256: base.tlsSPKISHA256,
                deviceID: base.deviceID,
                devicePublicKey: base.devicePublicKey,
                clientNonce: base.clientNonce,
                hostNonce: base.hostNonce,
                ticketSecretBindingSHA256: base.ticketSecretBindingSHA256,
                requestedScopes: base.requestedScopes
            )
        }
        #expect(throws: HarcProtocolCodecError.invalidDigest(field: "clientNonce")) {
            try PairingTranscriptV1(
                ticketID: base.ticketID,
                claimID: base.claimID,
                libraryID: base.libraryID,
                hostAuthorityID: base.hostAuthorityID,
                hostAuthorityPublicKey: base.hostAuthorityPublicKey,
                tlsSPKISHA256: base.tlsSPKISHA256,
                deviceID: base.deviceID,
                devicePublicKey: base.devicePublicKey,
                clientNonce: Data(repeating: 1, count: 31),
                hostNonce: base.hostNonce,
                ticketSecretBindingSHA256: base.ticketSecretBindingSHA256,
                requestedScopes: base.requestedScopes
            )
        }
        #expect(throws: HarcProtocolCodecError.nonCanonicalOrder(field: "requestedScopes")) {
            try PairingTranscriptV1(
                ticketID: base.ticketID,
                claimID: base.claimID,
                libraryID: base.libraryID,
                hostAuthorityID: base.hostAuthorityID,
                hostAuthorityPublicKey: base.hostAuthorityPublicKey,
                tlsSPKISHA256: base.tlsSPKISHA256,
                deviceID: base.deviceID,
                devicePublicKey: base.devicePublicKey,
                clientNonce: base.clientNonce,
                hostNonce: base.hostNonce,
                ticketSecretBindingSHA256: base.ticketSecretBindingSHA256,
                requestedScopes: [.recordingUploadOwn, .libraryMetadataRead]
            )
        }
        #expect(throws: HarcProtocolCodecError.duplicateValue(field: "requestedScopes")) {
            try PairingTranscriptV1(
                ticketID: base.ticketID,
                claimID: base.claimID,
                libraryID: base.libraryID,
                hostAuthorityID: base.hostAuthorityID,
                hostAuthorityPublicKey: base.hostAuthorityPublicKey,
                tlsSPKISHA256: base.tlsSPKISHA256,
                deviceID: base.deviceID,
                devicePublicKey: base.devicePublicKey,
                clientNonce: base.clientNonce,
                hostNonce: base.hostNonce,
                ticketSecretBindingSHA256: base.ticketSecretBindingSHA256,
                requestedScopes: [.recordingUploadOwn, .recordingUploadOwn]
            )
        }
    }

    @Test("frozen SAS dictionary hash and big-endian 44-bit word selection are enforced")
    func sasDictionaryAndBitOrder() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Protos/Fixtures/harc-sas-words-v1.txt")
        let fixtureBytes = try Data(contentsOf: fixtureURL)
        let dictionary = try HarcSASDictionaryV1(exactUTF8LFBytes: fixtureBytes)
        let bundledDictionary = try HarcSASDictionaryV1.bundled()
        let hostKey = ProtocolCodecFixtures.key(25)
        let deviceKey = ProtocolCodecFixtures.key(26)
        let transcript = try makeTranscript(hostKey: hostKey, deviceKey: deviceKey)
        let signature = try transcript.signClientProof(using: deviceKey)
        let phrase = try dictionary.phrase(for: transcript, clientSignature: signature)

        #expect(dictionary.words.count == 2_048)
        #expect(bundledDictionary == dictionary)
        #expect(dictionary.words.first == "abandon")
        #expect(dictionary.words.last == "zoo")
        #expect(Data(SHA256.hash(data: fixtureBytes)) == HarcSASDictionaryV1.expectedSHA256)
        #expect(phrase.indexes == referenceIndexes(phrase.digest))
        #expect(phrase.words == phrase.indexes.map { dictionary.words[$0] })
        #expect(phrase.displayedPhrase == phrase.words.joined(separator: " "))

        var corrupted = fixtureBytes
        corrupted[0] ^= 1
        #expect(throws: HarcProtocolCodecError.invalidSASDictionary) {
            try HarcSASDictionaryV1(exactUTF8LFBytes: corrupted)
        }
    }

    @Test("ticket secret binding includes the domain, exact UUID bytes, and 24-byte secret")
    func ticketSecretBinding() throws {
        let ticketID = ProtocolCodecFixtures.uuid(220)
        let secret = ProtocolCodecFixtures.bytes(0x44, count: 24)
        var reference = Data("HARC-PAIRING-TICKET-SECRET-V1\0".utf8)
        reference.append(withUnsafeBytes(of: ticketID.uuid) { Data($0) })
        reference.append(secret)
        #expect(try PairingTicketV1.ticketSecretBindingSHA256(
            ticketID: ticketID,
            secret: secret
        ) == Data(SHA256.hash(data: reference)))
    }

    private func makeTranscript(
        hostKey: SoftwareP256SigningKey,
        deviceKey: SoftwareP256SigningKey
    ) throws -> PairingTranscriptV1 {
        let ticketID = ProtocolCodecFixtures.uuid(200)
        return try PairingTranscriptV1(
            ticketID: ticketID,
            claimID: ProtocolCodecFixtures.uuid(201),
            libraryID: LibraryID(ProtocolCodecFixtures.uuid(202)),
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            hostAuthorityPublicKey: hostKey.publicKey,
            tlsSPKISHA256: ProtocolCodecFixtures.bytes(0x41),
            deviceID: deviceKey.publicKey.deviceID,
            devicePublicKey: deviceKey.publicKey,
            clientNonce: ProtocolCodecFixtures.bytes(0x42),
            hostNonce: ProtocolCodecFixtures.bytes(0x43),
            ticketSecretBindingSHA256: try PairingTicketV1.ticketSecretBindingSHA256(
                ticketID: ticketID,
                secret: ProtocolCodecFixtures.bytes(0x44, count: 24)
            ),
            requestedScopes: [.libraryMetadataRead, .recordingUploadOwn]
        )
    }

    private func referenceIndexes(_ digest: Data) -> [Int] {
        let bytes = [UInt8](digest)
        return (0 ..< 4).map { wordIndex in
            (0 ..< 11).reduce(0) { partial, bitOffset in
                let absoluteBit = wordIndex * 11 + bitOffset
                let byte = bytes[absoluteBit / 8]
                let bit = (byte >> UInt8(7 - absoluteBit % 8)) & 1
                return (partial << 1) | Int(bit)
            }
        }
    }
}
