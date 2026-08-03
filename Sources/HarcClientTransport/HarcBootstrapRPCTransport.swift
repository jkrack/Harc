import Foundation
import GRPCCore
import HarcProtocol

/// One protobuf response paired with the Harc-authenticated TLS facts observed
/// by the dedicated channel which carried it.
public struct HarcBootstrapRPCResponse<Message: Sendable>: Sendable {
    public let message: Message
    public let serverTrust: HarcAcceptedServerTrust

    public init(message: Message, serverTrust: HarcAcceptedServerTrust) {
        self.message = message
        self.serverTrust = serverTrust
    }
}

/// Socket-free application seam for the public bootstrap, pairing, and session
/// RPCs. Tests provide an in-memory implementation; production uses the
/// generated-client adapter below.
public protocol HarcBootstrapRPCTransport: Sendable {
    func getHostInfo(
        _ request: Harc_V1_GetHostInfoRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_GetHostInfoResponseV1>

    func negotiateCapabilities(
        _ request: Harc_V1_NegotiateCapabilitiesRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_NegotiateCapabilitiesResponseV1>

    func beginPairingClaim(
        _ request: Harc_V1_BeginPairingClaimRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_BeginPairingClaimResponseV1>

    func provePairingClaim(
        _ request: Harc_V1_ProvePairingClaimRequestV1,
        claimantToken: Data
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_ProvePairingClaimResponseV1>

    func getPairingStatus(
        _ request: Harc_V1_GetPairingStatusRequestV1,
        claimantToken: Data
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_GetPairingStatusResponseV1>

    func beginSession(
        _ request: Harc_V1_BeginSessionRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_BeginSessionResponseV1>

    func openSession(
        _ request: Harc_V1_OpenSessionRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_OpenSessionResponseV1>
}

/// Concrete adapter over the generated gRPC Swift 2 clients. The three clients
/// must wrap the same dedicated `GRPCClient` and consume response bindings from
/// that client's TLS/HTTP2 pipeline codec.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct HarcGeneratedBootstrapRPCAdapter<
    HostInfoClient: Harc_V1_HostInfoService.ClientProtocol,
    PairingClient: Harc_V1_PairingService.ClientProtocol,
    SessionClient: Harc_V1_SessionService.ClientProtocol
>: HarcBootstrapRPCTransport {
    private let hostInfoClient: HostInfoClient
    private let pairingClient: PairingClient
    private let sessionClient: SessionClient
    private let responseTrustCodec: HarcGRPCResponseTrustCodec

    init(
        hostInfoClient: HostInfoClient,
        pairingClient: PairingClient,
        sessionClient: SessionClient,
        responseTrustCodec: HarcGRPCResponseTrustCodec
    ) {
        self.hostInfoClient = hostInfoClient
        self.pairingClient = pairingClient
        self.sessionClient = sessionClient
        self.responseTrustCodec = responseTrustCodec
    }

    public func getHostInfo(
        _ request: Harc_V1_GetHostInfoRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_GetHostInfoResponseV1> {
        try await hostInfoClient.getHostInfo(
            request,
            onResponse: authenticated
        )
    }

    public func negotiateCapabilities(
        _ request: Harc_V1_NegotiateCapabilitiesRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_NegotiateCapabilitiesResponseV1> {
        try await hostInfoClient.negotiateCapabilities(
            request,
            onResponse: authenticated
        )
    }

    public func beginPairingClaim(
        _ request: Harc_V1_BeginPairingClaimRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_BeginPairingClaimResponseV1> {
        try await pairingClient.beginPairingClaim(
            request,
            onResponse: authenticated
        )
    }

    public func provePairingClaim(
        _ request: Harc_V1_ProvePairingClaimRequestV1,
        claimantToken: Data
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_ProvePairingClaimResponseV1> {
        try await pairingClient.provePairingClaim(
            request,
            metadata: Self.pairingAuthorizationMetadata(claimantToken),
            onResponse: authenticated
        )
    }

    public func getPairingStatus(
        _ request: Harc_V1_GetPairingStatusRequestV1,
        claimantToken: Data
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_GetPairingStatusResponseV1> {
        try await pairingClient.getPairingStatus(
            request,
            metadata: Self.pairingAuthorizationMetadata(claimantToken),
            onResponse: authenticated
        )
    }

    public func beginSession(
        _ request: Harc_V1_BeginSessionRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_BeginSessionResponseV1> {
        try await sessionClient.beginSession(
            request,
            onResponse: authenticated
        )
    }

    public func openSession(
        _ request: Harc_V1_OpenSessionRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_OpenSessionResponseV1> {
        try await sessionClient.openSession(
            request,
            onResponse: authenticated
        )
    }

    private func authenticated<Message: Sendable>(
        _ response: ClientResponse<Message>
    ) throws -> HarcBootstrapRPCResponse<Message> {
        // Preserve the underlying gRPC error for trailers-only failures. A
        // successful message must also carry a locally sealed physical-channel
        // trust envelope or the response fails closed.
        let message = try response.message
        let trust = try responseTrustCodec.trust(from: response.metadata)
        return HarcBootstrapRPCResponse(
            message: message,
            serverTrust: trust
        )
    }

    private static func pairingAuthorizationMetadata(
        _ claimantToken: Data
    ) -> Metadata {
        var metadata = Metadata()
        metadata.addString(
            "HarcPairing \(HarcBootstrapAuthorization.base64URL(claimantToken))",
            forKey: "authorization"
        )
        return metadata
    }
}

public enum HarcBootstrapAuthorization {
    public static func sessionHeader(credential: Data) throws -> String {
        guard credential.count == 48 else {
            throw HarcBootstrapClientError.invalidResponse(
                field: "sessionCredential"
            )
        }
        return "HarcSession \(base64URL(credential))"
    }

    static func base64URL(_ bytes: Data) -> String {
        bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
