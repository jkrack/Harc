import Foundation
import Testing
@testable import HarcIdentity

@Suite("P-256 verification adversarial and captured vectors")
struct P256VerificationCorpusTests {
    @Test("pinned Wycheproof raw-signature corpus preserves canonical validation")
    func wycheproofCorpus() throws {
        let corpus: Corpus = try fixture("ecdsa_secp256r1_sha256_p1363_test")
        #expect(corpus.numberOfTests == 262)
        var valid = 0
        var invalid = 0
        let invalidHighSCaseIDs: Set<Int> = [4, 21, 35, 205, 254, 256, 258, 259, 260]
        var canonicalizedInvalidCaseIDs: Set<Int> = []
        for group in corpus.testGroups {
            let key = try P256X963PublicKey(try decodeHex(group.publicKey.uncompressed))
            for vector in group.tests {
                let raw = try decodeHex(vector.sig)
                let digest = P256SHA256Digest(hashing: try decodeHex(vector.msg))
                let context = "Wycheproof tcId \(vector.tcId)"
                if vector.result == "valid" {
                    valid += 1
                    // Wycheproof's generic ECDSA profile permits either S form.
                    // Only the canonical low-S representation enters Harc.
                    let canonical = try P256RawSignature.normalizing(raw)
                    #expect(key.isValidSignature(canonical, for: digest), "\(context)")
                    try rejectsChangedInputs(key: key, signature: canonical, digest: digest)
                    if raw != canonical.rawBytes {
                        #expect(throws: IdentityCryptoError.signatureNotLowS) {
                            try P256RawSignature(raw)
                        }
                    }
                } else {
                    #expect(vector.result == "invalid", "\(context)")
                    invalid += 1
                    if invalidHighSCaseIDs.contains(vector.tcId) {
                        // Keep the external rejection, then exercise the verifier
                        // with the equivalent in-range low-S invalid signature.
                        // This normalization is test-only; wire input stays strict.
                        #expect(throws: IdentityCryptoError.signatureNotLowS) {
                            try P256RawSignature(raw)
                        }
                        let canonical = try P256RawSignature.normalizing(raw)
                        #expect(!key.isValidSignature(canonical, for: digest), "\(context)")
                        canonicalizedInvalidCaseIDs.insert(vector.tcId)
                    } else if let signature = try? P256RawSignature(raw) {
                        #expect(!key.isValidSignature(signature, for: digest), "\(context)")
                    }
                }
            }
        }
        #expect(valid == 173)
        #expect(invalid == 89)
        #expect(valid + invalid == corpus.numberOfTests)
        #expect(canonicalizedInvalidCaseIDs == invalidHighSCaseIDs)
    }

    @Test("all five captured valid signatures verify and reject changed inputs")
    func capturedCorpus() throws {
        let corpus: CapturedCorpus = try fixture("harc-captured-p256")
        let key = try P256X963PublicKey(try decodeHex(corpus.publicKeyX963Hex))
        let vectors = corpus.vectors + [corpus.transportCapture]
        #expect(vectors.count == 5)
        for vector in vectors {
            let digest = try P256SHA256Digest(try decodeHex(vector.digestHex))
            let signature = try P256RawSignature(try decodeHex(vector.rawSignatureHex))
            #expect(key.isValidSignature(signature, for: digest))
            try rejectsChangedInputs(key: key, signature: signature, digest: digest)
        }
    }

    private func rejectsChangedInputs(
        key: P256X963PublicKey,
        signature: P256RawSignature,
        digest: P256SHA256Digest
    ) throws {
        var changed = digest.rawBytes
        changed[0] ^= 1
        #expect(!key.isValidSignature(signature, for: try P256SHA256Digest(changed)))
        #expect(!key.isValidSignature(
            signature, for: P256SHA256Digest(hashing: digest.rawBytes)
        ))
        var changedSignature = signature.rawBytes
        changedSignature[0] ^= 1
        if let altered = try? P256RawSignature(changedSignature) {
            #expect(!key.isValidSignature(altered, for: digest))
        }
    }

    private func fixture<T: Decodable>(_ name: String) throws -> T {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private func decodeHex(_ input: String) throws -> Data {
        let characters = Array(input.utf8)
        try #require(characters.count.isMultiple(of: 2))
        var bytes: [UInt8] = []
        for offset in stride(from: 0, to: characters.count, by: 2) {
            let string = try #require(String(
                bytes: characters[offset..<offset + 2], encoding: .utf8
            ))
            bytes.append(try #require(UInt8(string, radix: 16)))
        }
        return Data(bytes)
    }

    private struct Corpus: Decodable {
        let numberOfTests: Int
        let testGroups: [Group]
        struct Group: Decodable {
            let publicKey: Key
            let tests: [Vector]
        }
        struct Key: Decodable { let uncompressed: String }
        struct Vector: Decodable {
            let tcId: Int
            let msg: String
            let sig: String
            let result: String
        }
    }

    private struct CapturedCorpus: Decodable {
        let publicKeyX963Hex: String
        let vectors: [Vector]
        let transportCapture: Vector
        struct Vector: Decodable {
            let digestHex: String
            let rawSignatureHex: String
        }
    }
}
