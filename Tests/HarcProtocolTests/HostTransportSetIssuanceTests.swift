import Foundation
import HarcDomain
@testable import HarcIdentity
@testable import HarcProtocol
import Testing

@Suite("Host transport set issuance")
struct HostTransportSetIssuanceTests {
    @Test("issuer reproduces the frozen exact transport object and object ID")
    func exactGoldenIssuance() throws {
        let golden = try TransportSetGoldenFixture.load()
        let payload = try HostTransportSetV1.decode(golden.payload)
        let goldenObject = try HarcSignedObjectV1.decode(golden.frame)
        let hostKey = ProtocolCodecFixtures.key(10)
        let signer = FixedTransportSetSigner(
            publicKey: hostKey.publicKey,
            expectedDigest: HarcSignedObjectV1.signingDigest(
                forExactHeaderBytes: goldenObject.exactHeaderBytes
            ),
            signature: goldenObject.signature
        )

        let issued = try VerifiedHostTransportSetV1.issue(
            protocolVersion: payload.protocolVersion,
            libraryID: payload.libraryID,
            hostAuthorityID: payload.hostAuthorityID,
            setEpoch: payload.setEpoch,
            issuedAtUnixMilliseconds: payload.issuedAtUnixMilliseconds,
            entries: payload.entries,
            using: signer
        )

        #expect(issued.transportSet == payload)
        #expect(issued.hostAuthorityPublicKey == hostKey.publicKey)
        #expect(issued.signedObject.exactPayloadBytes == golden.payload)
        #expect(issued.exactSignedBytes == golden.frame)
        #expect(issued.signedObject.objectID == goldenObject.objectID)
        #expect(
            try VerifiedHostTransportSetV1.decode(
                issued.exactSignedBytes,
                hostAuthorityPublicKey: hostKey.publicKey
            ) == issued
        )
    }

    @Test("issuer rejects an authority tuple mismatch and re-verifies signer output")
    func authorityAndSignatureBinding() throws {
        let hostKey = ProtocolCodecFixtures.key(20)
        let otherKey = ProtocolCodecFixtures.key(21)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(200))
        let entry = try transportEntry(0x31)

        #expect(throws: HarcProtocolCodecError.invalidKeyBinding(
            field: "hostAuthorityID"
        )) {
            try VerifiedHostTransportSetV1.issue(
                libraryID: libraryID,
                hostAuthorityID: otherKey.publicKey.hostAuthorityID,
                setEpoch: 1,
                issuedAtUnixMilliseconds: ProtocolCodecFixtures.issuedAt,
                entries: [entry],
                using: hostKey
            )
        }

        let invalidSigner = MismatchedTransportSetSigner(
            publicKey: hostKey.publicKey,
            actualSigner: otherKey
        )
        #expect(throws: HarcProtocolCodecError.invalidSignature) {
            try VerifiedHostTransportSetV1.issue(
                libraryID: libraryID,
                hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                setEpoch: 1,
                issuedAtUnixMilliseconds: ProtocolCodecFixtures.issuedAt,
                entries: [entry],
                using: invalidSigner
            )
        }
    }

    @Test("issuer rejects zero epochs and noncanonical entry sets")
    func epochAndCanonicalEntryValidation() throws {
        let hostKey = ProtocolCodecFixtures.key(22)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(220))
        let first = try transportEntry(0x41)
        let second = try transportEntry(0x42)
        let third = try transportEntry(0x43)

        #expect(throws: HarcProtocolCodecError.lengthOutOfRange(
            field: "setEpoch",
            minimum: 1,
            maximum: UInt64.max,
            actual: 0
        )) {
            try issue(
                libraryID: libraryID,
                hostKey: hostKey,
                setEpoch: 0,
                entries: [first]
            )
        }
        #expect(throws: HarcProtocolCodecError.lengthOutOfRange(
            field: "transportEntries",
            minimum: 1,
            maximum: UInt64(HarcProtocolLimits.transportEntries),
            actual: 0
        )) {
            try issue(
                libraryID: libraryID,
                hostKey: hostKey,
                setEpoch: 1,
                entries: []
            )
        }
        #expect(throws: HarcProtocolCodecError.lengthOutOfRange(
            field: "transportEntries",
            minimum: 1,
            maximum: UInt64(HarcProtocolLimits.transportEntries),
            actual: 3
        )) {
            try issue(
                libraryID: libraryID,
                hostKey: hostKey,
                setEpoch: 1,
                entries: [first, second, third]
            )
        }
        #expect(throws: HarcProtocolCodecError.nonCanonicalOrder(
            field: "transportEntries"
        )) {
            try issue(
                libraryID: libraryID,
                hostKey: hostKey,
                setEpoch: 1,
                entries: [second, first]
            )
        }
        #expect(throws: HarcProtocolCodecError.duplicateValue(
            field: "transportEntries.tlsSPKISHA256"
        )) {
            try issue(
                libraryID: libraryID,
                hostKey: hostKey,
                setEpoch: 1,
                entries: [first, first]
            )
        }
    }

    private func issue(
        libraryID: LibraryID,
        hostKey: SoftwareP256SigningKey,
        setEpoch: UInt64,
        entries: [HostTransportEntryV1]
    ) throws -> VerifiedHostTransportSetV1 {
        try VerifiedHostTransportSetV1.issue(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            setEpoch: setEpoch,
            issuedAtUnixMilliseconds: ProtocolCodecFixtures.issuedAt,
            entries: entries,
            using: hostKey
        )
    }

    private func transportEntry(_ byte: UInt8) throws -> HostTransportEntryV1 {
        try HostTransportEntryV1(
            tlsSPKISHA256: ProtocolCodecFixtures.bytes(byte),
            notBeforeUnixMilliseconds: ProtocolCodecFixtures.issuedAt - 1_000,
            notAfterUnixMilliseconds: ProtocolCodecFixtures.issuedAt + 60_000
        )
    }
}

private struct FixedTransportSetSigner: P256DigestSigner {
    let publicKey: P256X963PublicKey
    let expectedDigest: P256SHA256Digest
    let signature: P256RawSignature

    func sign(digest: P256SHA256Digest) throws -> P256RawSignature {
        guard digest == expectedDigest else {
            throw TransportSetIssuanceTestError.unexpectedSigningDigest
        }
        return signature
    }
}

private struct MismatchedTransportSetSigner: P256DigestSigner {
    let publicKey: P256X963PublicKey
    let actualSigner: SoftwareP256SigningKey

    func sign(digest: P256SHA256Digest) throws -> P256RawSignature {
        try actualSigner.sign(digest: digest)
    }
}

private struct TransportSetGoldenFixture {
    let payload: Data
    let frame: Data

    static func load() throws -> Self {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Protos/Fixtures/harc-wire-v1-golden.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        var values: [String: Data] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let columns = rawLine.split(
                separator: "|",
                omittingEmptySubsequences: false
            )
            guard columns.count >= 2 else { continue }
            let key = String(columns[0])
            guard key == "transport.payload" || key == "transport.frame" else {
                continue
            }
            guard let value = Data(base64Encoded: String(columns[1])) else {
                throw TransportSetIssuanceTestError.invalidGoldenValue(key)
            }
            values[key] = value
        }
        guard let payload = values["transport.payload"],
              let frame = values["transport.frame"] else {
            throw TransportSetIssuanceTestError.missingGoldenTransportSet
        }
        return Self(payload: payload, frame: frame)
    }
}

private enum TransportSetIssuanceTestError: Error {
    case invalidGoldenValue(String)
    case missingGoldenTransportSet
    case unexpectedSigningDigest
}
