import Foundation
import Testing
@testable import HarcIdentity

@Suite("HarcIdentity P-256 signing profile")
struct P256SigningTests {
    // RFC 6979 Appendix A.2.5, P-256 / SHA-256 / message "sample".
    // RFC's S is high, so the fixture uses the equivalent n-S required by Harc.
    private let publicKeyHex = """
        04
        60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6
        7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299
        """
    private let digestHex = "AF2BDBE1AA9B6EC1E2ADE1D694F41FC71A831D0268E9891562113D8A62ADD1BF"
    private let lowSignatureHex = """
        EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716
        0834E36AD29A83BF2BC9385E491D6099C8FDF9D1ED67AA7EA5F51F93782857A9
        """
    private let highSignatureHex = """
        EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716
        F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8
        """

    @Test("RFC 6979 vector verifies as a single prehash and detects double hashing")
    func independentVectorAndDoubleHashDetection() throws {
        let publicKey = try P256X963PublicKey(try Data(hex: publicKeyHex))
        let digest = try P256SHA256Digest(try Data(hex: digestHex))
        let signature = try P256RawSignature(try Data(hex: lowSignatureHex))

        #expect(publicKey.isValidSignature(signature, for: digest))

        let accidentallyDoubleHashed = P256SHA256Digest(hashing: digest.rawBytes)
        #expect(!publicKey.isValidSignature(signature, for: accidentallyDoubleHashed))
    }

    private let capturedPublicKeyHex = """
        04
        f0454dc6971abae7adfb378999888265ae03af92de3a0ef163668c63e59b9d5f
        b5b93ee3592e2d1f4e6594e51f9643e62a3b21ce75b5fa3f47e59cde0d034f36
        """

    // Captured from the software-only scalar-15 diagnostic on macOS 26.6.2.
    // OpenSSL 3.6.2 and an independent P-256 equation check accept this low-S
    // vector. Apple CryptoKit/SecKey reject it on the affected development Mac.
    // Keep the positive assertion: retries or an expected-failure annotation
    // would hide the same failure class as the relay-admission CI anomaly.
    @Test("captured valid low-S signature remains interoperable")
    func capturedLowSSignatureInteroperability() throws {
        let publicKey = try P256X963PublicKey(try Data(hex: capturedPublicKeyHex))
        let digestBytes = try Data(hex:
            "76d7b73faeb2bbecd43b6176ee41da3db2b0c7cf6528fac3435f0950ed22afae"
        )
        #expect(digestBytes == Data(SHA256Reference.hash(
            Data("harc-signature-diagnostic-12".utf8)
        )))
        let signature = try P256RawSignature(try Data(hex: """
            bb1f1b082fdd7aeb5c396d109374e5445a5a7dc5957b15ec59aa27f1a79208f4
            3977eccab3ee08d969a77b3b52910487847b07b360b442ac8821bb97d77f2976
            """))
        let digest = try P256SHA256Digest(digestBytes)
        #expect(publicKey.isValidSignature(signature, for: digest))

        // A verifier change must still reject a changed message and double hash.
        var changedDigestBytes = digestBytes
        changedDigestBytes[0] ^= 1
        #expect(!publicKey.isValidSignature(
            signature,
            for: try P256SHA256Digest(changedDigestBytes)
        ))
        #expect(!publicKey.isValidSignature(
            signature,
            for: P256SHA256Digest(hashing: digestBytes)
        ))
    }

    @Test("captured valid Host transport signature remains interoperable")
    func capturedTransportSignatureInteroperability() throws {
        let publicKey = try P256X963PublicKey(try Data(hex: capturedPublicKeyHex))
        // Exact signing prehash/signature from the failed transport-set frame
        // preserved in docs/evidence/2026-10-15-p256-verification-vectors.json.
        let digest = try P256SHA256Digest(try Data(hex:
            "d59617b34da3428bb9e35906612d8c7ffdb12a3b8213d5c97a687828c1e3bab8"
        ))
        let signature = try P256RawSignature(try Data(hex: """
            8fd3457d89a4450a0d568c007f961b0bbb496b07b5f91295e8b98970836ee8c1
            290c1b6ad1723e75f4dc080492c75a26f737b1bbf1ad60f8070c269d56acff28
            """))
        #expect(publicKey.isValidSignature(signature, for: digest))
    }

    @Test("identity derivation uses the exact versioned X9.63 domain separator")
    func identityDerivationVector() throws {
        let publicKey = try P256X963PublicKey(try Data(hex: publicKeyHex))
        let expected = try Data(
            hex: "4b2ffa99a8bb770429dd61344944440db047de8027b61cd5d7cfd9e6ffdcfa7d"
        )

        #expect(publicKey.deviceID.rawBytes == expected)
        #expect(publicKey.hostAuthorityID.rawBytes == expected)
        #expect(publicKey.deviceID.rawBytes != Data(SHA256Reference.hash(publicKey.rawBytes)))
    }

    @Test("strict X9.63 keys reject compressed, wrong-length, and off-curve bytes")
    func strictPublicKeyValidation() throws {
        let valid = try Data(hex: publicKeyHex)
        #expect(throws: IdentityCryptoError.invalidPublicKeyLength(expected: 65, actual: 64)) {
            try P256X963PublicKey(valid.dropLastData())
        }

        var compressed = valid
        compressed[compressed.startIndex] = 0x02
        #expect(throws: IdentityCryptoError.invalidPublicKeyPrefix(actual: 0x02)) {
            try P256X963PublicKey(compressed)
        }

        var offCurve = valid
        offCurve[offCurve.index(after: offCurve.startIndex)] ^= 0xff
        #expect(throws: IdentityCryptoError.invalidPublicKey) {
            try P256X963PublicKey(offCurve)
        }
    }

    @Test("high-S and malformed signatures fail before cryptographic verification")
    func highSAndScalarRejection() throws {
        #expect(throws: IdentityCryptoError.signatureNotLowS) {
            try P256RawSignature(try Data(hex: highSignatureHex))
        }
        #expect(throws: IdentityCryptoError.invalidSignatureScalar) {
            try P256RawSignature(Data(repeating: 0, count: 64))
        }
        #expect(throws: IdentityCryptoError.invalidSignatureLength(expected: 64, actual: 63)) {
            try P256RawSignature(Data(repeating: 1, count: 63))
        }
    }

    @Test("software signing always emits raw low-S signatures and tampering fails")
    func softwareSigningAndTamperRejection() throws {
        let key = SoftwareP256SigningKey()
        let digest = P256SHA256Digest(hashing: Data("HARC-test-signing-input".utf8))

        for counter in 0..<32 {
            var bytes = digest.rawBytes
            bytes.append(UInt8(counter))
            let currentDigest = P256SHA256Digest(hashing: bytes)
            let signature = try key.sign(digest: currentDigest)
            #expect(signature.rawBytes.count == 64)
            #expect(key.publicKey.isValidSignature(signature, for: currentDigest))

            var tamperedDigestBytes = currentDigest.rawBytes
            tamperedDigestBytes[tamperedDigestBytes.startIndex] ^= 0x01
            let tamperedDigest = try P256SHA256Digest(tamperedDigestBytes)
            #expect(!key.publicKey.isValidSignature(signature, for: tamperedDigest))
        }
    }

    @Test("validated crypto values retain invariants through Codable")
    func codableRoundTripAndDecodeValidation() throws {
        let key = try P256X963PublicKey(try Data(hex: publicKeyHex))
        let signature = try P256RawSignature(try Data(hex: lowSignatureHex))
        let digest = try P256SHA256Digest(try Data(hex: digestHex))

        #expect(try roundTrip(key) == key)
        #expect(try roundTrip(signature) == signature)
        #expect(try roundTrip(digest) == digest)

        let invalidDigest = try JSONEncoder().encode(Data(repeating: 0, count: 31))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(P256SHA256Digest.self, from: invalidDigest)
        }
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
}

private enum SHA256Reference {
    static func hash(_ data: Data) -> Data {
        // A local test-only helper intentionally constructs the non-domain-separated
        // comparison through Harc's digest type without using an ID API.
        P256SHA256Digest(hashing: data).rawBytes
    }
}

private extension Data {
    init(hex: String) throws {
        let compact = hex.filter { !$0.isWhitespace }
        guard compact.count.isMultiple(of: 2) else { throw HexError.invalid }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let end = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<end], radix: 16) else {
                throw HexError.invalid
            }
            bytes.append(byte)
            index = end
        }
        self.init(bytes)
    }

    func dropLastData() -> Data { Data(dropLast()) }
}

private enum HexError: Error { case invalid }
