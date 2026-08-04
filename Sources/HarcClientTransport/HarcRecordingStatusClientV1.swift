import HarcDomain
import HarcProtocol
import HarcTransfer

/// Narrow, request-bound status reader shared by the CLI and future clients.
/// Raw protobuf responses never escape without validation against the exact
/// lookup key sent on the authenticated session.
public struct HarcRecordingStatusClientV1: Sendable {
    private let rpc: HarcValidatedRecordingTransferRPCClientV1

    public init(
        transport: any HarcRecordingTransferRPCTransport,
        openedSession: HarcOpenedClientSession,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) throws {
        rpc = HarcValidatedRecordingTransferRPCClientV1(
            transport: transport,
            authorization: try HarcRecordingTransferAuthorization(
                openedSession: openedSession
            ),
            compatibility: compatibility
        )
    }

    public func status(
        uploadID: UploadID,
        protocolVersion: HarcProtocolVersion = .v1
    ) async throws -> HarcValidatedGetRecordingStatusResponseV1 {
        var request = Harc_V1_GetRecordingStatusRequestV1()
        request.protocol = protocolVersion.protobufV1()
        request.uploadID = Harc_V1_UploadIDV1(uploadID)
        return try await rpc.getRecordingStatus(request)
    }

    public func status(
        originRecordingID: OriginRecordingID,
        protocolVersion: HarcProtocolVersion = .v1
    ) async throws -> HarcValidatedGetRecordingStatusResponseV1 {
        var request = Harc_V1_GetRecordingStatusRequestV1()
        request.protocol = protocolVersion.protobufV1()
        request.originRecordingID = Harc_V1_OriginRecordingIDV1(
            originRecordingID
        )
        return try await rpc.getRecordingStatus(request)
    }
}
