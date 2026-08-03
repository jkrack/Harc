import Foundation
import GRPCCore
import HarcProtocol

/// A fail-closed authorization value for post-session recording RPCs.
///
/// Callers can only derive this value from an opened Harc session. The
/// credential and header are checked against one another once, then the gRPC
/// adapter emits exactly one canonical `authorization` metadata value for each
/// RPC. The header is intentionally not exposed because it is bearer material.
public struct HarcRecordingTransferAuthorization: Sendable {
    fileprivate let headerValue: String

    public init(openedSession: HarcOpenedClientSession) throws {
        try self.init(
            credential: openedSession.credential,
            authorizationHeader: openedSession.authorizationHeader
        )
    }

    init(credential: Data, authorizationHeader: String) throws {
        guard let canonicalHeader = try? HarcBootstrapAuthorization.sessionHeader(
            credential: credential
        ), canonicalHeader == authorizationHeader else {
            throw HarcRecordingTransferAuthorizationError
                .invalidOpenedSessionAuthorization
        }
        self.headerValue = canonicalHeader
    }

    fileprivate var metadata: Metadata {
        var metadata = Metadata()
        metadata.addString(headerValue, forKey: "authorization")
        return metadata
    }
}

public enum HarcRecordingTransferAuthorizationError: Error, Equatable, Sendable {
    case invalidOpenedSessionAuthorization
}

/// A type-erased, backpressured writer for a recording upload request stream.
/// `write(_:)` suspends until the underlying gRPC stream accepts the message.
public struct HarcUploadChunkRequestWriter: Sendable {
    private let writeImplementation: @Sendable (
        Harc_V1_UploadChunkRequestV1
    ) async throws -> Void

    public init(
        write: @escaping @Sendable (
            Harc_V1_UploadChunkRequestV1
        ) async throws -> Void
    ) {
        self.writeImplementation = write
    }

    public func write(
        _ request: Harc_V1_UploadChunkRequestV1
    ) async throws {
        try await writeImplementation(request)
    }
}

public typealias HarcUploadChunkRequestProducer = @Sendable (
    HarcUploadChunkRequestWriter
) async throws -> Void

public typealias HarcUploadChunkResponseConsumer = @Sendable (
    Harc_V1_UploadChunkResponseV1
) async throws -> Void

/// Application-facing seam for the session-authenticated recording-transfer
/// service. Unary calls return one protobuf response. `uploadChunks` is a true
/// bidirectional stream: each request write and response callback is awaited,
/// preserving transport backpressure without buffering the recording or all
/// acknowledgements in memory.
public protocol HarcRecordingTransferRPCTransport: Sendable {
    func beginUpload(
        _ request: Harc_V1_BeginUploadRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_BeginUploadResponseV1

    func declareChunks(
        _ request: Harc_V1_DeclareChunksRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_DeclareChunksResponseV1

    func uploadChunks(
        authorization: HarcRecordingTransferAuthorization,
        requestProducer: @escaping HarcUploadChunkRequestProducer,
        responseConsumer: @escaping HarcUploadChunkResponseConsumer
    ) async throws

    func reconcileUpload(
        _ request: Harc_V1_ReconcileUploadRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_ReconcileUploadResponseV1

    func commitUpload(
        _ request: Harc_V1_CommitUploadRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_CommitUploadResponseV1

    func abandonUpload(
        _ request: Harc_V1_AbandonUploadRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_AbandonUploadResponseV1

    func getRecordingStatus(
        _ request: Harc_V1_GetRecordingStatusRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_GetRecordingStatusResponseV1

    func mintBackgroundUploadAuthorization(
        _ request: Harc_V1_MintBackgroundCapabilityRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_MintBackgroundCapabilityResponseV1
}

/// Concrete adapter over the generated gRPC Swift 2 recording-transfer client.
/// Production constructs it with a stub wrapping the same dedicated, pinned
/// `GRPCClient` used for bootstrap and session establishment.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct HarcGeneratedRecordingTransferRPCAdapter<
    RecordingTransferClient: Harc_V1_RecordingTransferService.ClientProtocol
>: HarcRecordingTransferRPCTransport {
    private let client: RecordingTransferClient

    init(client: RecordingTransferClient) {
        self.client = client
    }

    public func beginUpload(
        _ request: Harc_V1_BeginUploadRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_BeginUploadResponseV1 {
        try await client.beginUpload(
            request,
            metadata: authorization.metadata
        )
    }

    public func declareChunks(
        _ request: Harc_V1_DeclareChunksRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_DeclareChunksResponseV1 {
        try await client.declareChunks(
            request,
            metadata: authorization.metadata
        )
    }

    public func uploadChunks(
        authorization: HarcRecordingTransferAuthorization,
        requestProducer: @escaping HarcUploadChunkRequestProducer,
        responseConsumer: @escaping HarcUploadChunkResponseConsumer
    ) async throws {
        try await client.uploadChunks(
            metadata: authorization.metadata,
            requestProducer: { grpcWriter in
                let writer = HarcUploadChunkRequestWriter { request in
                    try await grpcWriter.write(request)
                }
                try await requestProducer(writer)
            },
            onResponse: { response in
                for try await message in response.messages {
                    try await responseConsumer(message)
                }
            }
        )
    }

    public func reconcileUpload(
        _ request: Harc_V1_ReconcileUploadRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_ReconcileUploadResponseV1 {
        try await client.reconcileUpload(
            request,
            metadata: authorization.metadata
        )
    }

    public func commitUpload(
        _ request: Harc_V1_CommitUploadRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_CommitUploadResponseV1 {
        try await client.commitUpload(
            request,
            metadata: authorization.metadata
        )
    }

    public func abandonUpload(
        _ request: Harc_V1_AbandonUploadRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_AbandonUploadResponseV1 {
        try await client.abandonUpload(
            request,
            metadata: authorization.metadata
        )
    }

    public func getRecordingStatus(
        _ request: Harc_V1_GetRecordingStatusRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_GetRecordingStatusResponseV1 {
        try await client.getRecordingStatus(
            request,
            metadata: authorization.metadata
        )
    }

    public func mintBackgroundUploadAuthorization(
        _ request: Harc_V1_MintBackgroundCapabilityRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_MintBackgroundCapabilityResponseV1 {
        try await client.mintBackgroundCapability(
            request,
            metadata: authorization.metadata
        )
    }
}
