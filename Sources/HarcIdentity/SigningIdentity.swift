import Foundation
import HarcDomain

/// The two signing-key roles in the v1 identity profile.
public enum SigningIdentityRole: String, Codable, CaseIterable, Sendable {
    case hostAuthority
    case device
}

/// A typed stable identifier prevents a device key from being confused with a
/// host-authority key even though both use the same versioned derivation bytes.
public enum StableSigningIdentityID: Hashable, Sendable, Codable {
    case hostAuthority(HostAuthorityID)
    case device(DeviceID)
}

/// Public, portable identity material. It contains no private-key reference.
public struct PublicSigningIdentity: Hashable, Sendable, Codable {
    public let role: SigningIdentityRole
    public let publicKey: P256X963PublicKey

    public init(role: SigningIdentityRole, publicKey: P256X963PublicKey) {
        self.role = role
        self.publicKey = publicKey
    }

    public var stableID: StableSigningIdentityID {
        switch role {
        case .hostAuthority:
            return .hostAuthority(publicKey.hostAuthorityID)
        case .device:
            return .device(publicKey.deviceID)
        }
    }
}

/// The installation identity used before capture and independently of pairing.
/// It intentionally provides signing but no private-key export surface.
public struct InstallationSigningIdentity: P256DigestSigner, Sendable {
    private let key: InstallationSigningKey

    init(key: InstallationSigningKey) {
        self.key = key
    }

    public var publicKey: P256X963PublicKey { key.publicKey }
    public var deviceID: DeviceID { publicKey.deviceID }
    public var keyProtection: InstallationKeyProtection { key.protection }
    public var publicIdentity: PublicSigningIdentity {
        PublicSigningIdentity(role: .device, publicKey: publicKey)
    }

    public func sign(digest: P256SHA256Digest) throws -> P256RawSignature {
        try key.sign(digest: digest)
    }

    public func originRecordingID(recordingUUID: UUID = UUID()) -> OriginRecordingID {
        OriginRecordingID(deviceID: deviceID, recordingUUID: recordingUUID)
    }
}
