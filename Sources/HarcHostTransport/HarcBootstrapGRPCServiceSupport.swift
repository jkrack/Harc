import Foundation
import GRPCCore
import HarcHost
import HarcProtocol

enum HarcHostBootstrapGRPCAdapterError: Error {
    case invalidPairingAuthorization
    case invalidServerTime
    case controlRequestTooLarge
}

enum HarcHostBootstrapGRPCServiceSupport {
    /// The bootstrap server transport applies this ceiling to the raw,
    /// uncompressed gRPC message before protobuf decoding. The adapter repeats
    /// it below as defense in depth for in-memory and future alternate entry
    /// points which already hold a decoded message.
    static let maximumControlRequestBytes = 1 * 1_024 * 1_024

    private static let maximumExactlyRepresentableUnixMilliseconds: UInt64 =
        9_007_199_254_740_991

    static func peer(from context: ServerContext) -> HarcHostRPCPeer {
        HarcHostRPCPeer(
            remotePeer: context.remotePeer,
            localPeer: context.localPeer
        )
    }

    static func admit(
        metadata: Metadata,
        peer: HarcHostRPCPeer,
        sourceBindingProvider: HarcHostRPCSourceBindingProvider,
        gate: HarcBootstrapPreauthenticationGate
    ) async throws -> HostPreauthenticationSource {
        let internalSourceValues = Array(
            metadata[HarcGRPCTransportSourceBridge.metadataKey]
        )
        let source: HostPreauthenticationSource
        if internalSourceValues.isEmpty {
            // gRPC's Network.framework custom-listener seam currently reports
            // `<unknown>` peers. A real stream therefore requires the
            // transport-injected token. The strict peer parser remains only
            // for direct adapter tests and alternate transports which expose
            // a concrete numeric IP or canonical UDS peer.
            source = try sourceBindingProvider.sourceBinding(for: peer)
        } else {
            guard internalSourceValues.count == 1,
                  case .binary(let token) = internalSourceValues[0] else {
                throw HarcHostRPCSourceBindingError
                    .invalidAuthenticatedTransportSource
            }
            source = try sourceBindingProvider.sourceBinding(
                authenticatedTransportSourceToken: Data(token)
            )
        }
        try await gate.admit(source)
        return source
    }

    static func validateRequest<Value: Sendable>(
        source: HostPreauthenticationSource,
        gate: HarcBootstrapPreauthenticationGate,
        _ body: () throws -> Value
    ) async throws -> Value {
        do {
            return try body()
        } catch {
            do {
                try await gate.recordMalformedRequest(from: source)
            } catch {
                throw mapError(error)
            }
            throw mapError(error)
        }
    }

    static func validateControlRequestBytes(_ bytes: Data) throws {
        guard bytes.count <= maximumControlRequestBytes else {
            throw HarcHostBootstrapGRPCAdapterError.controlRequestTooLarge
        }
    }

    static func pairingClaimantToken(from metadata: Metadata) throws -> Data {
        let authorizationValues = Array(metadata["authorization"])
        guard authorizationValues.count == 1,
              case .string(let authorization) = authorizationValues[0],
              authorization.hasPrefix("HarcPairing ") else {
            throw HarcHostBootstrapGRPCAdapterError.invalidPairingAuthorization
        }
        let encoded = String(authorization.dropFirst("HarcPairing ".count))
        guard encoded.count == 43,
              encoded.utf8.allSatisfy({ byte in
                  (byte >= 0x41 && byte <= 0x5a)
                      || (byte >= 0x61 && byte <= 0x7a)
                      || (byte >= 0x30 && byte <= 0x39)
                      || byte == 0x2d || byte == 0x5f
              }) else {
            throw HarcHostBootstrapGRPCAdapterError.invalidPairingAuthorization
        }

        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        guard let token = Data(base64Encoded: base64),
              token.count == 32,
              base64URL(token) == encoded else {
            throw HarcHostBootstrapGRPCAdapterError.invalidPairingAuthorization
        }
        return token
    }

    static func unixMilliseconds(_ date: Date) throws -> UInt64 {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0 else {
            throw HarcHostBootstrapGRPCAdapterError.invalidServerTime
        }
        let scaled = seconds * 1_000
        guard scaled.isFinite,
              scaled <= Double(maximumExactlyRepresentableUnixMilliseconds) else {
            throw HarcHostBootstrapGRPCAdapterError.invalidServerTime
        }
        return UInt64(scaled.rounded(.towardZero))
    }

    static func mapError(_ error: any Error) -> RPCError {
        if let rpcError = error as? RPCError {
            return rpcError
        }
        if let adapterError = error as? HarcHostBootstrapGRPCAdapterError {
            switch adapterError {
            case .invalidPairingAuthorization:
                return RPCError(
                    code: .unauthenticated,
                    message: "Pairing authentication was rejected."
                )
            case .invalidServerTime:
                return RPCError(
                    code: .internalError,
                    message: "The host could not encode its response."
                )
            case .controlRequestTooLarge:
                return RPCError(
                    code: .invalidArgument,
                    message: "The request is malformed."
                )
            }
        }
        if error is HarcHostRPCSourceBindingError {
            return RPCError(
                code: .invalidArgument,
                message: "The request is malformed."
            )
        }
        if let admissionError = error
            as? HarcBootstrapPreauthenticationAdmissionError {
            switch admissionError {
            case .malformedRequestCooldown, .sourceCapacityExhausted:
                return RPCError(
                    code: .resourceExhausted,
                    message: "The request rate limit was exceeded."
                )
            case .monotonicClockRegression:
                return RPCError(
                    code: .unavailable,
                    message: "The host is temporarily unavailable."
                )
            }
        }
        if error is HarcGRPCServedIdentityBindingError {
            return RPCError(
                code: .unavailable,
                message: "The host is temporarily unavailable."
            )
        }
        if let conversionError = error as? HarcProtobufConversionError {
            switch conversionError {
            case .unsupportedRequiredFeature, .unknownCriticalField:
                return RPCError(
                    code: .failedPrecondition,
                    message: "The request requires unsupported protocol semantics."
                )
            default:
                return RPCError(
                    code: .invalidArgument,
                    message: "The request is malformed."
                )
            }
        }
        if let codecError = error as? HarcProtocolCodecError {
            switch codecError {
            case .unsupportedProtocolMajor, .unsupportedProtocolMinor:
                return RPCError(
                    code: .failedPrecondition,
                    message: "The protocol version is unsupported."
                )
            default:
                return RPCError(
                    code: .invalidArgument,
                    message: "The request is malformed."
                )
            }
        }
        if let hostError = error as? HarcHostError {
            switch hostError {
            case .invalidAuthenticationInput, .invalidHostInfoInput:
                return RPCError(
                    code: .invalidArgument,
                    message: "The request is malformed."
                )
            case .publicHostInfoRateLimited:
                return RPCError(
                    code: .resourceExhausted,
                    message: "The request rate limit was exceeded."
                )
            case .pairingClaimRejected, .pairingProofRejected,
                 .sessionAdmissionRejected, .sessionProofRejected,
                 .sessionCredentialRejected:
                return RPCError(
                    code: .unauthenticated,
                    message: "Authentication was rejected."
                )
            default:
                return RPCError(
                    code: .internalError,
                    message: "The host could not complete the request."
                )
            }
        }
        return RPCError(
            code: .internalError,
            message: "The host could not complete the request."
        )
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
