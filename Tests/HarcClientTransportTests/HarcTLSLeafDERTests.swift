#if canImport(Network)
import Foundation
import Testing
@testable import HarcClientTransport

@Suite("Strict raw-DER Harc TLS leaf parser")
struct HarcTLSLeafDERTests {
    @Test("the exact self-signed P-256 profile exposes full-DER SPKI and exact set")
    func parsesExactProfile() throws {
        let authority = try TransportTrustFixtures.authorityKey()
        let tls = try TransportTrustFixtures.tlsKey()
        let transport = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 1
        )
        let certificate = try TransportTrustFixtures.leafCertificate(
            tlsKey: tls,
            exactTransportSet: transport.exactSignedBytes
        )

        let facts = try HarcTLSLeafDERParser.parse(certificate)

        #expect(facts.certificateDER == certificate)
        #expect(
            facts.fullDERSPKISHA256
                == TransportTrustFixtures.spkiSHA256(for: tls)
        )
        #expect(facts.exactSignedTransportSet == transport.exactSignedBytes)
        #expect(
            facts.publicKeyX963.rawBytes == tls.publicKey.x963Representation
        )
    }

    @Test("hostile lengths and trailing DER are bounded and rejected")
    func hostileDERBounds() throws {
        let hostileLength = Data(
            [0x30, 0x88] + [UInt8](repeating: 0xff, count: 8)
        )
        #expect(throws: HarcTLSLeafDERError.malformedDER) {
            try HarcTLSLeafDERParser.parse(hostileLength)
        }
        #expect(
            throws: HarcTLSLeafDERError.inputTooLarge(
                actual: HarcTLSLeafDERParser.maximumCertificateBytes + 1,
                maximum: HarcTLSLeafDERParser.maximumCertificateBytes
            )
        ) {
            try HarcTLSLeafDERParser.parse(
                Data(
                    repeating: 0,
                    count: HarcTLSLeafDERParser.maximumCertificateBytes + 1
                )
            )
        }

        let authority = try TransportTrustFixtures.authorityKey()
        let tls = try TransportTrustFixtures.tlsKey()
        let transport = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 1
        )
        var trailing = try TransportTrustFixtures.leafCertificate(
            tlsKey: tls,
            exactTransportSet: transport.exactSignedBytes
        )
        trailing.append(0)
        #expect(throws: HarcTLSLeafDERError.malformedDER) {
            try HarcTLSLeafDERParser.parse(trailing)
        }
    }

    @Test(
        "missing duplicate critical oversized or malformed required extensions fail closed",
        arguments: [
            TransportTrustFixtures.ExtensionProfile.missingTransportSet,
            .duplicateTransportSet,
            .criticalTransportSet,
            .wrongKeyUsage,
            .oversizedTransportSet,
        ]
    )
    func rejectsInvalidExtensionProfiles(
        profile: TransportTrustFixtures.ExtensionProfile
    ) throws {
        let authority = try TransportTrustFixtures.authorityKey()
        let tls = try TransportTrustFixtures.tlsKey()
        let transport = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 1
        )
        let certificate = try TransportTrustFixtures.leafCertificate(
            tlsKey: tls,
            exactTransportSet: transport.exactSignedBytes,
            profile: profile
        )

        #expect(throws: HarcTLSLeafDERError.self) {
            try HarcTLSLeafDERParser.parse(certificate)
        }
    }

    @Test("the self-signature is checked over the exact TBSCertificate bytes")
    func rejectsInvalidSelfSignature() throws {
        let authority = try TransportTrustFixtures.authorityKey()
        let tls = try TransportTrustFixtures.tlsKey()
        let transport = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 1
        )
        var certificate = try TransportTrustFixtures.leafCertificate(
            tlsKey: tls,
            exactTransportSet: transport.exactSignedBytes
        )
        certificate[certificate.index(before: certificate.endIndex)] ^= 0x01

        #expect(throws: HarcTLSLeafDERError.self) {
            try HarcTLSLeafDERParser.parse(certificate)
        }
    }
}
#endif
