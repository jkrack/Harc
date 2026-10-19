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

    // Synthetic scalar-65 TLS fixture captured on macOS 26.6.2. OpenSSL accepts
    // its self-signature; affected Apple verifiers reject the original S form.
    // Keep a fixed positive assertion instead of retrying certificate generation.
    @Test(
        "a captured valid TLS self-signature remains interoperable in both S forms",
        arguments: [
            """
            MIIBmDCCAT6gAwIBAgIBATAKBggqhkjOPQQDAjAaMRgwFgYDVQQDDA9IYXJjIExvY2FsIEhvc3Qw
            HhcNMzMwNTE4MDMzMjUwWhcNMzMwNTE4MDQzMzIwWjAaMRgwFgYDVQQDDA9IYXJjIExvY2FsIEhv
            c3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQ0Ml3LRY2OWzQ9BTVTfdXgnHBGr8vzn2YRqi7C
            VOo0EIVo0dxQKVVHls0jjElnZxh5Tes+rXb+uG87FgHzyGnJo3UwczAMBgNVHRMBAf8EAjAAMA4G
            A1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDATA+BhRpgd7o67TArLqpza70wum36bv2
            VAQmc3ludGhldGljIHNpZ25lZCB0cmFuc3BvcnQtc2V0IGZpeHR1cmUwCgYIKoZIzj0EAwIDSAAw
            RQIhAMt3ZI77SnvbzwmQaPYDuDyaW2UiFXl5fAIq6kLBMe4QAiBy9Qh3u3RxmEg66vjNlUhQr1zi
            Ui6WEDPEC4ShrXGgGA==
            """,
            """
            MIIBmTCCAT6gAwIBAgIBATAKBggqhkjOPQQDAjAaMRgwFgYDVQQDDA9IYXJjIExvY2FsIEhvc3Qw
            HhcNMzMwNTE4MDMzMjUwWhcNMzMwNTE4MDQzMzIwWjAaMRgwFgYDVQQDDA9IYXJjIExvY2FsIEhv
            c3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQ0Ml3LRY2OWzQ9BTVTfdXgnHBGr8vzn2YRqi7C
            VOo0EIVo0dxQKVVHls0jjElnZxh5Tes+rXb+uG87FgHzyGnJo3UwczAMBgNVHRMBAf8EAjAAMA4G
            A1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDATA+BhRpgd7o67TArLqpza70wum36bv2
            VAQmc3ludGhldGljIHNpZ25lZCB0cmFuc3BvcnQtc2V0IGZpeHR1cmUwCgYIKoZIzj0EAwIDSQAw
            RgIhAMt3ZI77SnvbzwmQaPYDuDyaW2UiFXl5fAIq6kLBMe4QAiEAjQr3h0SLjmi3xRUHMmq3rw2K
            GFt4gY5RL65GIU7xhTk=
            """
        ]
    )
    func capturedSelfSignatureInteroperability(certificateBase64: String) throws {
        let certificate = try #require(Data(
            base64Encoded: certificateBase64,
            options: .ignoreUnknownCharacters
        ))
        let transport = Data("synthetic signed transport-set fixture".utf8)
        let facts = try HarcTLSLeafDERParser.parse(certificate)
        #expect(facts.certificateDER == certificate)
        #expect(facts.exactSignedTransportSet == transport)
        let tls = try TransportTrustFixtures.tlsKey()
        #expect(facts.publicKeyX963.rawBytes == tls.publicKey.x963Representation)

        var changedTBS = certificate
        let transportRange = try #require(changedTBS.range(of: transport))
        changedTBS[transportRange.lowerBound] ^= 1
        #expect(throws: HarcTLSLeafDERError.invalidSelfSignature) {
            try HarcTLSLeafDERParser.parse(changedTBS)
        }
        var changedSignature = certificate
        changedSignature[changedSignature.index(before: changedSignature.endIndex)] ^= 1
        #expect(throws: HarcTLSLeafDERError.invalidSelfSignature) {
            try HarcTLSLeafDERParser.parse(changedSignature)
        }
    }

    @Test(
        "malformed and out-of-range self-signature scalars fail closed",
        arguments: [
            "MAYCAQECAQA=",
            "MCYCAQECIQD/////AAAAAP//////////vOb6racXnoTzucrC/GMlUQ==",
            "MCYCAQECIQD/////AAAAAP//////////vOb6racXnoTzucrC/GMlUg==",
            "MCYCAQECIQD//////////////////////////////////////////w==",
            "MAYCAQACAQE=",
            "MCYCIQD/////AAAAAP//////////vOb6racXnoTzucrC/GMlUQIBAQ==",
            "MCYCIQD/////AAAAAP//////////vOb6racXnoTzucrC/GMlUgIBAQ==",
            "MCYCIQD//////////////////////////////////////////wIBAQ==",
            "MAcCAgABAgEB",
            "MAYCAYACAQE="
        ]
    )
    func malformedSelfSignatureScalars(signatureBase64: String) throws {
        let tls = try TransportTrustFixtures.tlsKey()
        let signature = try #require(Data(base64Encoded: signatureBase64))
        let certificate = try TransportTrustFixtures.leafCertificate(
            tlsKey: tls,
            exactTransportSet: Data("synthetic signed transport-set fixture".utf8),
            signatureDEROverride: signature
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
