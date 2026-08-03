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
