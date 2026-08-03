import CryptoKit
import Foundation
import Security

public enum SecureEnclaveSigningKeyError: Error, Equatable, Sendable {
    case unavailable
    case accessControlCreationFailed
    case invalidKeyReference
}

/// Noninteractive Secure Enclave P-256 signing key preferred by production
/// installation identity selection when the capability is present.
public struct SecureEnclaveP256SigningKey: P256DigestSigner, Sendable {
    private let privateKey: SecureEnclave.P256.Signing.PrivateKey

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    public init() throws {
        guard SecureEnclave.isAvailable else {
            throw SecureEnclaveSigningKeyError.unavailable
        }
        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            [.privateKeyUsage],
            &accessControlError
        ) else {
            throw SecureEnclaveSigningKeyError.accessControlCreationFailed
        }
        do {
            privateKey = try SecureEnclave.P256.Signing.PrivateKey(
                accessControl: accessControl
            )
        } catch {
            throw SecureEnclaveSigningKeyError.invalidKeyReference
        }
    }

    init(opaqueDataRepresentation: Data) throws {
        guard SecureEnclave.isAvailable else {
            throw SecureEnclaveSigningKeyError.unavailable
        }
        do {
            privateKey = try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: opaqueDataRepresentation
            )
        } catch {
            throw SecureEnclaveSigningKeyError.invalidKeyReference
        }
    }

    public var publicKey: P256X963PublicKey {
        try! P256X963PublicKey(privateKey.publicKey.x963Representation)
    }

    public func sign(digest: P256SHA256Digest) throws -> P256RawSignature {
        let signature = try privateKey.signature(
            for: PrecomputedSHA256Digest(digest.rawBytes)
        )
        return try P256RawSignature.normalizing(signature.rawRepresentation)
    }

    /// CryptoKit's same-device opaque reference, not private-key material.
    var persistedOpaqueDataRepresentation: Data { privateKey.dataRepresentation }
}
