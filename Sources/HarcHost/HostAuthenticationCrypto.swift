import CryptoKit
import Foundation
import HarcDomain

enum HostAuthenticationCrypto {
    private static let pairingClaimTokenDomain = Data(
        "HARC-PAIRING-CLAIM-TOKEN-V1\0".utf8
    )
    private static let sessionTokenDomain = Data("HARC-SESSION-TOKEN-V1\0".utf8)
    private static let preauthenticationSubjectDomain = Data(
        "HARC-PREAUTH-SUBJECT-V1\0".utf8
    )

    static func pairingClaimTokenBinding(claimID: UUID, token: Data) throws -> Data {
        guard token.count == SHA256.Digest.byteCount else {
            throw HarcHostError.invalidAuthenticationInput("claimant token")
        }
        return sha256(pairingClaimTokenDomain, uuidBytes(claimID), token)
    }

    static func sessionTokenBinding(tokenID: UUID, secret: Data) throws -> Data {
        guard secret.count == SHA256.Digest.byteCount else {
            throw HarcHostError.invalidAuthenticationInput("session token secret")
        }
        return sha256(sessionTokenDomain, uuidBytes(tokenID), secret)
    }

    static func preauthenticationSubject(deviceID: DeviceID) -> Data {
        sha256(preauthenticationSubjectDomain, deviceID.rawBytes)
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        let lhsBytes = [UInt8](lhs)
        let rhsBytes = [UInt8](rhs)
        for index in lhsBytes.indices {
            difference |= lhsBytes[index] ^ rhsBytes[index]
        }
        return difference == 0
    }

    static func uuidBytes(_ value: UUID) -> Data {
        withUnsafeBytes(of: value.uuid) { Data($0) }
    }

    static func uuid(from bytes: Data) -> UUID? {
        guard bytes.count == 16 else { return nil }
        let values = [UInt8](bytes)
        return UUID(uuid: (
            values[0], values[1], values[2], values[3],
            values[4], values[5], values[6], values[7],
            values[8], values[9], values[10], values[11],
            values[12], values[13], values[14], values[15]
        ))
    }

    private static func sha256(_ components: Data...) -> Data {
        var hasher = SHA256()
        for component in components { hasher.update(data: component) }
        return Data(hasher.finalize())
    }

}

enum HostAuthenticationRetention {
    static let terminalRowLifetime: TimeInterval = 7 * 24 * 60 * 60
}

/// Shared with the future QR controller without exposing the rest of the
/// authentication implementation surface.
public enum HostPairingSecretBinding {
    public static func sha256(
        ticketID: UUID,
        secret: Data,
        using boundary: any HostPairingTicketBindingBoundary
    ) throws -> Data {
        try boundary.pairingTicketSecretBindingSHA256(
            ticketID: ticketID,
            secret: secret
        )
    }
}
