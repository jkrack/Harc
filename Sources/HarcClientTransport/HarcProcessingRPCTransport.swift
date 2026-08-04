import Foundation
import GRPCCore
import HarcProtocol

/// Fail-closed authorization for session-authenticated processing RPCs.
public struct HarcProcessingAuthorization: Sendable {
    fileprivate let headerValue: String

    public init(openedSession: HarcOpenedClientSession) throws {
        guard let canonical = try? HarcBootstrapAuthorization.sessionHeader(
            credential: openedSession.credential
        ), canonical == openedSession.authorizationHeader else {
            throw HarcProcessingAuthorizationError
                .invalidOpenedSessionAuthorization
        }
        headerValue = canonical
    }

    init(validatedHeaderValueForTesting headerValue: String) {
        self.headerValue = headerValue
    }

    fileprivate var metadata: Metadata {
        var metadata = Metadata()
        metadata.addString(headerValue, forKey: "authorization")
        return metadata
    }
}

public enum HarcProcessingAuthorizationError: Error, Equatable, Sendable {
    case invalidOpenedSessionAuthorization
}

/// Backpressured request writer for the bounded processing bundle stream.
public struct HarcProcessingRequestWriter: Sendable {
    private let implementation: @Sendable (
        Harc_V1_SubmitOwnArtifactRequestV1
    ) async throws -> Void

    public init(
        write: @escaping @Sendable (
            Harc_V1_SubmitOwnArtifactRequestV1
        ) async throws -> Void
    ) {
        implementation = write
    }

    public func write(
        _ request: Harc_V1_SubmitOwnArtifactRequestV1
    ) async throws {
        try await implementation(request)
    }
}

public typealias HarcProcessingRequestProducer = @Sendable (
    HarcProcessingRequestWriter
) async throws -> Void

public protocol HarcProcessingRPCTransport: Sendable {
    func submitOwnArtifact(
        authorization: HarcProcessingAuthorization,
        requestProducer: @escaping HarcProcessingRequestProducer
    ) async throws -> Harc_V1_SubmitOwnArtifactResponseV1

    func getProcessingStatus(
        _ request: Harc_V1_GetProcessingStatusRequestV1,
        authorization: HarcProcessingAuthorization
    ) async throws -> Harc_V1_GetProcessingStatusResponseV1
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct HarcGeneratedProcessingRPCAdapter<
    ProcessingClient: Harc_V1_ProcessingService.ClientProtocol
>: HarcProcessingRPCTransport {
    private let client: ProcessingClient

    init(client: ProcessingClient) {
        self.client = client
    }

    public func submitOwnArtifact(
        authorization: HarcProcessingAuthorization,
        requestProducer: @escaping HarcProcessingRequestProducer
    ) async throws -> Harc_V1_SubmitOwnArtifactResponseV1 {
        try await client.submitOwnArtifact(
            metadata: authorization.metadata,
            requestProducer: { grpcWriter in
                let writer = HarcProcessingRequestWriter { request in
                    try await grpcWriter.write(request)
                }
                try await requestProducer(writer)
            }
        )
    }

    public func getProcessingStatus(
        _ request: Harc_V1_GetProcessingStatusRequestV1,
        authorization: HarcProcessingAuthorization
    ) async throws -> Harc_V1_GetProcessingStatusResponseV1 {
        try await client.getProcessingStatus(
            request,
            metadata: authorization.metadata
        )
    }
}
