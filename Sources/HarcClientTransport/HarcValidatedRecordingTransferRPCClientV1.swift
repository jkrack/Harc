import Foundation
import HarcProtocol

/// A request-bound view of the raw recording-transfer RPC seam.
///
/// The expected response binding is always derived from the exact request that
/// is sent. Callers therefore cannot accidentally opt out of response/request
/// validation or validate a response against a separately constructed value.
struct HarcValidatedRecordingTransferRPCClientV1: Sendable {
    private let transport: any HarcRecordingTransferRPCTransport
    private let authorization: HarcRecordingTransferAuthorization
    private let compatibility: HarcProtobufCompatibilityPolicy

    init(
        transport: any HarcRecordingTransferRPCTransport,
        authorization: HarcRecordingTransferAuthorization,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) {
        self.transport = transport
        self.authorization = authorization
        self.compatibility = compatibility
    }

    func beginUpload(
        _ request: Harc_V1_BeginUploadRequestV1
    ) async throws -> HarcValidatedBeginUploadResponseV1 {
        let expected = try HarcValidatedBeginUploadRequestV1(
            request,
            compatibility: compatibility
        )
        try Task.checkCancellation()
        let response = try await transport.beginUpload(
            request,
            authorization: authorization
        )
        return try validateRecordingTransferResponse {
            try HarcValidatedBeginUploadResponseV1(
                response,
                expectedRequest: expected,
                compatibility: compatibility
            )
        }
    }

    func declareChunks(
        _ request: Harc_V1_DeclareChunksRequestV1
    ) async throws -> HarcValidatedDeclareChunksResponseV1 {
        let expected = try HarcValidatedDeclareChunksRequestV1(
            request,
            compatibility: compatibility
        )
        try Task.checkCancellation()
        let response = try await transport.declareChunks(
            request,
            authorization: authorization
        )
        return try validateRecordingTransferResponse {
            try HarcValidatedDeclareChunksResponseV1(
                response,
                expectedRequest: expected,
                compatibility: compatibility
            )
        }
    }

    /// Sends one bounded chunk per stream. The stream callback cannot expose a
    /// response until it is bound to this exact request, and completion is not
    /// successful unless exactly one validated response was observed.
    func uploadChunk(
        _ request: Harc_V1_UploadChunkRequestV1,
        onValidatedResponse: @escaping @Sendable (
            HarcValidatedUploadChunkResponseV1
        ) async throws -> Void
    ) async throws {
        let expected = try HarcValidatedUploadChunkRequestV1(
            request,
            compatibility: compatibility
        )
        let gate = HarcSingleUploadResponseGateV1(
            expectedRequest: expected,
            compatibility: compatibility
        )
        try Task.checkCancellation()
        try await transport.uploadChunks(
            authorization: authorization,
            requestProducer: { writer in
                try Task.checkCancellation()
                try await writer.write(request)
            },
            responseConsumer: { response in
                let validated = try await gate.accept(response)
                try await onValidatedResponse(validated)
            }
        )
        try await gate.requireExactlyOneResponse()
    }

    func reconcileUpload(
        _ request: Harc_V1_ReconcileUploadRequestV1
    ) async throws -> HarcValidatedReconcileUploadResponseV1 {
        let expected = try HarcValidatedReconcileUploadRequestV1(
            request,
            compatibility: compatibility
        )
        try Task.checkCancellation()
        let response = try await transport.reconcileUpload(
            request,
            authorization: authorization
        )
        return try validateRecordingTransferResponse {
            try HarcValidatedReconcileUploadResponseV1(
                response,
                expectedRequest: expected,
                compatibility: compatibility
            )
        }
    }

    func commitUpload(
        _ request: Harc_V1_CommitUploadRequestV1
    ) async throws -> HarcValidatedCommitUploadResponseV1 {
        let expected = try HarcValidatedCommitUploadRequestV1(
            request,
            compatibility: compatibility
        )
        try Task.checkCancellation()
        let response = try await transport.commitUpload(
            request,
            authorization: authorization
        )
        return try validateRecordingTransferResponse {
            try HarcValidatedCommitUploadResponseV1(
                response,
                expectedRequest: expected,
                compatibility: compatibility
            )
        }
    }

    func getRecordingStatus(
        _ request: Harc_V1_GetRecordingStatusRequestV1
    ) async throws -> HarcValidatedGetRecordingStatusResponseV1 {
        let expected = try HarcValidatedGetRecordingStatusRequestV1(
            request,
            compatibility: compatibility
        )
        try Task.checkCancellation()
        let response = try await transport.getRecordingStatus(
            request,
            authorization: authorization
        )
        return try validateRecordingTransferResponse {
            try HarcValidatedGetRecordingStatusResponseV1(
                response,
                expectedRequest: expected,
                compatibility: compatibility
            )
        }
    }
}

enum HarcValidatedRecordingTransferRPCError: Error, Equatable, Sendable {
    case missingUploadChunkResponse
    case multipleUploadChunkResponses
    case responseValidationFailed(String)
}

/// Keeps transport failures distinct while collapsing every semantic decode or
/// request-binding failure at the untrusted response boundary into one error
/// family. Callers can therefore apply the same fail-closed policy to unary and
/// streaming responses without having to know every protocol error type.
private func validateRecordingTransferResponse<Value>(
    _ validation: () throws -> Value
) throws -> Value {
    do {
        return try validation()
    } catch let error as HarcValidatedRecordingTransferRPCError {
        throw error
    } catch {
        throw HarcValidatedRecordingTransferRPCError.responseValidationFailed(
            String(reflecting: error)
        )
    }
}

private actor HarcSingleUploadResponseGateV1 {
    private let expectedRequest: HarcValidatedUploadChunkRequestV1
    private let compatibility: HarcProtobufCompatibilityPolicy
    private var responseCount = 0

    init(
        expectedRequest: HarcValidatedUploadChunkRequestV1,
        compatibility: HarcProtobufCompatibilityPolicy
    ) {
        self.expectedRequest = expectedRequest
        self.compatibility = compatibility
    }

    func accept(
        _ response: Harc_V1_UploadChunkResponseV1
    ) throws -> HarcValidatedUploadChunkResponseV1 {
        guard responseCount == 0 else {
            throw HarcValidatedRecordingTransferRPCError
                .multipleUploadChunkResponses
        }
        let validated = try validateRecordingTransferResponse {
            try HarcValidatedUploadChunkResponseV1(
                response,
                expectedRequest: expectedRequest,
                compatibility: compatibility
            )
        }
        responseCount = 1
        return validated
    }

    func requireExactlyOneResponse() throws {
        guard responseCount == 1 else {
            throw HarcValidatedRecordingTransferRPCError
                .missingUploadChunkResponse
        }
    }
}
