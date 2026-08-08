import Foundation

/// Canonical user-directed file representation of a short-lived pairing URI.
/// Harc never persists these bytes automatically; callers may export or import
/// them only through an explicit system save/open/share surface.
public enum PairingInvitationFileV1 {
    public static let contentTypeIdentifier =
        "com.harc.pairing-invitation"
    public static let filenameExtension = "harcpair"
    public static let mimeType =
        "application/vnd.harc.pairing-invitation"
    public static let maximumByteCount =
        HarcProtocolLimits.pairingURIBytes

    public static func encode(
        pairingURI: String,
        atUnixMilliseconds now: UInt64
    ) throws -> Data {
        let exactBytes = Data(pairingURI.utf8)
        guard exactBytes.count <= maximumByteCount,
              String(data: exactBytes, encoding: .ascii) == pairingURI else {
            throw HarcProtocolCodecError.invalidPairingURI
        }
        _ = try PairingTicketV1.decodeURI(
            pairingURI,
            atUnixMilliseconds: now
        )
        return exactBytes
    }

    public static func decodeURI(
        _ exactBytes: Data,
        atUnixMilliseconds now: UInt64
    ) throws -> String {
        guard !exactBytes.isEmpty,
              exactBytes.count <= maximumByteCount,
              let pairingURI = String(data: exactBytes, encoding: .ascii),
              Data(pairingURI.utf8) == exactBytes else {
            throw HarcProtocolCodecError.invalidPairingURI
        }
        _ = try PairingTicketV1.decodeURI(
            pairingURI,
            atUnixMilliseconds: now
        )
        return pairingURI
    }
}
