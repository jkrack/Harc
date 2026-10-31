#if os(macOS) && canImport(Network)
import GRPCCore
import HarcProtocol
@testable import HarcHostTransport

/// Test-only server response fault. The real adapter completes authenticated
/// admission first; this wrapper then fails one reply over the real connection.
actor SpeakerReplyFailureGate {
    private var armed = false
    private(set) var failureCount = 0
    func arm() { armed = true }
    func consumeFailure() -> Bool {
        guard armed else { return false }
        armed = false; failureCount += 1; return true
    }
}

struct SpeakerReplyFailureService: Harc_V1_LibraryService.ServiceProtocol {
    let base: HarcLibraryGRPCServiceAdapterV1
    let gate: SpeakerReplyFailureGate

    func beginLibrarySnapshot(
        request: ServerRequest<Harc_V1_BeginLibrarySnapshotRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_BeginLibrarySnapshotResponseV1> {
        let response = try await base.beginLibrarySnapshot(request: request, context: context)
        return response
    }

    func listSnapshotPage(
        request: ServerRequest<Harc_V1_ListSnapshotPageRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_ListSnapshotPageResponseV1> {
        let response = try await base.listSnapshotPage(request: request, context: context)
        return response
    }

    func listChanges(
        request: ServerRequest<Harc_V1_ListChangesRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_ListChangesResponseV1> {
        let response = try await base.listChanges(request: request, context: context)
        return response
    }

    func getRecording(
        request: ServerRequest<Harc_V1_GetRecordingRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_GetRecordingResponseV1> {
        let response = try await base.getRecording(request: request, context: context)
        return response
    }

    func getAudio(
        request: ServerRequest<Harc_V1_GetAudioRequestV1>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Harc_V1_GetAudioResponseV1> {
        let response = try await base.getAudio(request: request, context: context)
        return response
    }

    func searchMetadata(
        request: ServerRequest<Harc_V1_SearchMetadataRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_SearchMetadataResponseV1> {
        let response = try await base.searchMetadata(request: request, context: context)
        return response
    }

    func searchTranscripts(
        request: ServerRequest<Harc_V1_SearchTranscriptsRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_SearchTranscriptsResponseV1> {
        let response = try await base.searchTranscripts(request: request, context: context)
        return response
    }

    func applyMetadataMutation(
        request: ServerRequest<Harc_V1_ApplyMetadataMutationRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_ApplyMetadataMutationResponseV1> {
        let response = try await base.applyMetadataMutation(request: request, context: context)
        return response
    }

    func getSpeakerRecognitionPack(
        request: ServerRequest<Harc_V1_GetSpeakerRecognitionPackRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_GetSpeakerRecognitionPackResponseV1> {
        let response = try await base.getSpeakerRecognitionPack(request: request, context: context)
        return response
    }

    func submitSpeakerObservation(
        request: ServerRequest<Harc_V1_SubmitSpeakerObservationRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_SubmitSpeakerObservationResponseV1> {
        let response = try await base.submitSpeakerObservation(request: request, context: context)
        if request.message.hasBoundObservation, await gate.consumeFailure() {
            throw RPCError(code: .unavailable, message: "Fixture reply failure after committed speaker decision")
        }
        return response
    }
}
#endif
