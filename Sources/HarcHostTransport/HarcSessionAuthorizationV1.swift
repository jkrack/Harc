import Foundation
import GRPCCore
import HarcHost
import HarcIdentity

enum HarcSessionAuthorizationV1Error: Error, Equatable, Sendable {
    case invalidAuthorization
}

/// Narrow authentication seam for post-session transport adapters. The host
/// service remains authoritative for credential, grant, scope, and TLS-binding
/// validation.
protocol HarcSessionCredentialAuthenticating: Sendable {
    func authenticate(
        credential: Data,
        tlsSPKISHA256: Data,
        requiredScope: AuthorizationScope?
    ) async throws -> HostAuthenticatedSession
}

extension HarcSessionService: HarcSessionCredentialAuthenticating {}

enum HarcSessionAuthorizationV1 {
    private static let scheme = "HarcSession "
    private static let encodedCredentialLength = 64
    private static let credentialLength = 48

    /// Parses exactly one canonical session credential. All malformed forms
    /// intentionally collapse to one error so the edge does not expose a
    /// credential-format oracle.
    static func credential(from metadata: Metadata) throws -> Data {
        let values = Array(metadata["authorization"])
        guard values.count == 1,
              case .string(let authorization) = values[0],
              authorization.hasPrefix(scheme) else {
            throw HarcSessionAuthorizationV1Error.invalidAuthorization
        }

        let encoded = String(authorization.dropFirst(scheme.count))
        guard encoded.count == encodedCredentialLength,
              encoded.utf8.allSatisfy({ isBase64URLCharacter($0) }),
              let credential = decodeBase64URL(encoded),
              credential.count == credentialLength,
              base64URL(credential) == encoded else {
            throw HarcSessionAuthorizationV1Error.invalidAuthorization
        }
        return credential
    }

    /// Authenticates a recording-transfer request against the TLS identity
    /// actually served by this listener generation and the frozen upload-own
    /// scope. Call streaming adapters at admission and again while active.
    static func authenticateRecordingUpload(
        metadata: Metadata,
        authenticator: any HarcSessionCredentialAuthenticating,
        servedIdentityBinding: HarcGRPCServedIdentityBinding
    ) async throws -> HostAuthenticatedSession {
        let credential = try credential(from: metadata)
        let tlsSPKISHA256 = try servedIdentityBinding.requireTLSSPKISHA256(
            generationID: servedIdentityBinding.generationID
        )
        return try await authenticator.authenticate(
            credential: credential,
            tlsSPKISHA256: tlsSPKISHA256,
            requiredScope: .recordingUploadOwn
        )
    }

    private static func isBase64URLCharacter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5a)
            || (byte >= 0x61 && byte <= 0x7a)
            || (byte >= 0x30 && byte <= 0x39)
            || byte == 0x2d
            || byte == 0x5f
    }

    private static func decodeBase64URL(_ encoded: String) -> Data? {
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(
            String(repeating: "=", count: (4 - base64.count % 4) % 4)
        )
        return Data(base64Encoded: base64)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
