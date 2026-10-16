// Public synthetic vector only. No Keychain, signing, network, or app access.
// Run: swift scripts/reproduce-p256-verification.swift
import CryptoKit
import Foundation

func bytes(_ hex: String) -> Data {
    let chars = Array(hex)
    precondition(chars.count.isMultiple(of: 2))
    return Data(stride(from: 0, to: chars.count, by: 2).map {
        UInt8(String(chars[$0 ... $0 + 1]), radix: 16)!
    })
}

let publicKey = try P256.Signing.PublicKey(x963Representation: bytes(
    "04f0454dc6971abae7adfb378999888265ae03af92de3a0ef163668c63e59b9d5f"
    + "b5b93ee3592e2d1f4e6594e51f9643e62a3b21ce75b5fa3f47e59cde0d034f36"
))
let signature = try P256.Signing.ECDSASignature(rawRepresentation: bytes(
    "bb1f1b082fdd7aeb5c396d109374e5445a5a7dc5957b15ec59aa27f1a79208f4"
    + "3977eccab3ee08d969a77b3b52910487847b07b360b442ac8821bb97d77f2976"
))
let message = Data("harc-signature-diagnostic-12".utf8)
let digest = SHA256.hash(data: message)
let accepted = publicKey.isValidSignature(signature, for: digest)
print("CryptoKit accepts captured valid low-S vector: \(accepted)")
let spki = bytes("3059301306072a8648ce3d020106082a8648ce3d030107034200")
    + publicKey.x963Representation
print("Public key SPKI DER base64: \(spki.base64EncodedString())")
print("Public key X9.63 base64: \(publicKey.x963Representation.base64EncodedString())")
print("Signature DER base64: \(signature.derRepresentation.base64EncodedString())")
print("Digest SHA-256: \(digest)")
if !accepted { exit(1) }
