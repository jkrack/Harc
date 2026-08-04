import Foundation
import GRPCCore
import HarcProtocol

/// Fail-closed authorization for session-authenticated library RPCs.
public struct HarcLibraryAuthorization: Sendable {
    fileprivate let headerValue: String

    public init(openedSession: HarcOpenedClientSession) throws {
        guard let canonical = try? HarcBootstrapAuthorization.sessionHeader(
            credential: openedSession.credential
        ), canonical == openedSession.authorizationHeader else {
            throw HarcLibraryAuthorizationError
                .invalidOpenedSessionAuthorization
        }
        headerValue = canonical
    }

    fileprivate var metadata: Metadata {
        var metadata = Metadata()
        metadata.addString(headerValue, forKey: "authorization")
        return metadata
    }
}

public enum HarcLibraryAuthorizationError: Error, Equatable, Sendable {
    case invalidOpenedSessionAuthorization
}

public typealias HarcLibraryAudioResponseConsumer = @Sendable (
    Harc_V1_GetAudioResponseV1
) async throws -> Void

public protocol HarcLibraryRPCTransport: Sendable {
    func beginLibrarySnapshot(
        _ request: Harc_V1_BeginLibrarySnapshotRequestV1,
        authorization: HarcLibraryAuthorization
    ) async throws -> Harc_V1_BeginLibrarySnapshotResponseV1

    func listSnapshotPage(
        _ request: Harc_V1_ListSnapshotPageRequestV1,
        authorization: HarcLibraryAuthorization
    ) async throws -> Harc_V1_ListSnapshotPageResponseV1

    func listLibraryChanges(
        _ request: Harc_V1_ListChangesRequestV1,
        authorization: HarcLibraryAuthorization
    ) async throws -> Harc_V1_ListChangesResponseV1

    func getLibraryRecording(
        _ request: Harc_V1_GetRecordingRequestV1,
        authorization: HarcLibraryAuthorization
    ) async throws -> Harc_V1_GetRecordingResponseV1

    func getLibraryAudio(
        _ request: Harc_V1_GetAudioRequestV1,
        authorization: HarcLibraryAuthorization,
        responseConsumer: @escaping HarcLibraryAudioResponseConsumer
    ) async throws

    func searchLibraryMetadata(
        _ request: Harc_V1_SearchMetadataRequestV1,
        authorization: HarcLibraryAuthorization
    ) async throws -> Harc_V1_SearchMetadataResponseV1

    func searchLibraryTranscripts(
        _ request: Harc_V1_SearchTranscriptsRequestV1,
        authorization: HarcLibraryAuthorization
    ) async throws -> Harc_V1_SearchTranscriptsResponseV1
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct HarcGeneratedLibraryRPCAdapter<
    LibraryClient: Harc_V1_LibraryService.ClientProtocol
>: HarcLibraryRPCTransport {
    private let client: LibraryClient

    init(client: LibraryClient) {
        self.client = client
    }

    public func beginLibrarySnapshot(
        _ request: Harc_V1_BeginLibrarySnapshotRequestV1,
        authorization: HarcLibraryAuthorization
    ) async throws -> Harc_V1_BeginLibrarySnapshotResponseV1 {
        try await client.beginLibrarySnapshot(
            request,
            metadata: authorization.metadata
        )
    }

    public func listSnapshotPage(
        _ request: Harc_V1_ListSnapshotPageRequestV1,
        authorization: HarcLibraryAuthorization
    ) async throws -> Harc_V1_ListSnapshotPageResponseV1 {
        try await client.listSnapshotPage(
            request,
            metadata: authorization.metadata
        )
    }

    public func listLibraryChanges(
        _ request: Harc_V1_ListChangesRequestV1,
        authorization: HarcLibraryAuthorization
    ) async throws -> Harc_V1_ListChangesResponseV1 {
        try await client.listChanges(
            request,
            metadata: authorization.metadata
        )
    }

    public func getLibraryRecording(
        _ request: Harc_V1_GetRecordingRequestV1,
        authorization: HarcLibraryAuthorization
    ) async throws -> Harc_V1_GetRecordingResponseV1 {
        try await client.getRecording(
            request,
            metadata: authorization.metadata
        )
    }

    public func getLibraryAudio(
        _ request: Harc_V1_GetAudioRequestV1,
        authorization: HarcLibraryAuthorization,
        responseConsumer: @escaping HarcLibraryAudioResponseConsumer
    ) async throws {
        try await client.getAudio(
            request,
            metadata: authorization.metadata,
            onResponse: { response in
                for try await message in response.messages {
                    try await responseConsumer(message)
                }
            }
        )
    }

    public func searchLibraryMetadata(
        _ request: Harc_V1_SearchMetadataRequestV1,
        authorization: HarcLibraryAuthorization
    ) async throws -> Harc_V1_SearchMetadataResponseV1 {
        try await client.searchMetadata(
            request,
            metadata: authorization.metadata
        )
    }

    public func searchLibraryTranscripts(
        _ request: Harc_V1_SearchTranscriptsRequestV1,
        authorization: HarcLibraryAuthorization
    ) async throws -> Harc_V1_SearchTranscriptsResponseV1 {
        try await client.searchTranscripts(
            request,
            metadata: authorization.metadata
        )
    }
}
