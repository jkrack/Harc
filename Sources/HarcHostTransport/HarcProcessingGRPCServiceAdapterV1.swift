import Foundation
import GRPCCore
import HarcDomain
import HarcHost
import HarcIdentity
import HarcProtocol

/// Session-authenticated edge for signed, bounded Mac processing artifacts.
public struct HarcProcessingGRPCServiceAdapterV1:
    Harc_V1_ProcessingService.ServiceProtocol, Sendable
{
    static let maximumFrameBytes = 1 * 1_024 * 1_024

    private let service: HarcHostProcessingArtifactService
    private let sessionAuthenticator: any HarcSessionCredentialAuthenticating
    private let servedIdentityBinding: HarcGRPCServedIdentityBinding
    private let compatibility: HarcProtobufCompatibilityPolicy

    init(
        service: HarcHostProcessingArtifactService,
        sessionService: HarcSessionService,
        servedIdentityBinding: HarcGRPCServedIdentityBinding,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) {
        self.service = service
        sessionAuthenticator = sessionService
        self.servedIdentityBinding = servedIdentityBinding
        self.compatibility = compatibility
    }

    public func submitOwnArtifact(
        request: StreamingServerRequest<
            Harc_V1_SubmitOwnArtifactRequestV1
        >,
        context: ServerContext
    ) async throws -> ServerResponse<
        Harc_V1_SubmitOwnArtifactResponseV1
    > {
        do {
            var session = try await authorize(
                request.metadata,
                requiredScope: .processingSubmitOwn
            )
            var exactSignedMetadata: Data?
            var bundle = Data()
            var expectedIndex: UInt32 = 0
            var expectedOffset: UInt64 = 0
            var messageCount = 0

            for try await message in request.messages {
                messageCount += 1
                try validateProtocol(message, session: session)
                switch message.value {
                case .begin(let begin):
                    guard messageCount == 1,
                          exactSignedMetadata == nil,
                          !begin.exactSignedProcessingArtifact
                            .framedBytes.isEmpty,
                          begin.exactSignedProcessingArtifact.framedBytes.count
                            <= HarcProtocolLimits.signedObjectBytes else {
                        throw HarcHostError.invalidAuthenticationInput(
                            "processing begin"
                        )
                    }
                    exactSignedMetadata = begin
                        .exactSignedProcessingArtifact.framedBytes
                case .frame(let frame):
                    guard exactSignedMetadata != nil,
                          frame.frameIndex == expectedIndex,
                          frame.byteOffset == expectedOffset,
                          !frame.data.isEmpty,
                          frame.data.count <= Self.maximumFrameBytes,
                          bundle.count
                            <= HarcProcessingBundleV1.maximumExactBytes
                                - frame.data.count else {
                        throw HarcHostError.invalidAuthenticationInput(
                            "processing frame"
                        )
                    }
                    bundle.append(frame.data)
                    expectedIndex &+= 1
                    expectedOffset += UInt64(frame.data.count)
                case nil:
                    throw HarcHostError.invalidAuthenticationInput(
                        "processing stream value"
                    )
                }
                session = try await authorize(
                    request.metadata,
                    requiredScope: .processingSubmitOwn
                )
            }
            guard let exactSignedMetadata, !bundle.isEmpty else {
                throw HarcHostError.invalidAuthenticationInput(
                    "processing stream completion"
                )
            }
            let result = try await service.submit(
                session: session,
                exactSignedMetadata: exactSignedMetadata,
                exactBundle: bundle
            )
            return ServerResponse(
                message: try Self.response(
                    result,
                    protocolMinor: session.protocolMinor
                )
            )
        } catch {
            throw HarcPostSessionGRPCErrorMapper.map(error)
        }
    }

    public func getProcessingStatus(
        request: ServerRequest<Harc_V1_GetProcessingStatusRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<
        Harc_V1_GetProcessingStatusResponseV1
    > {
        do {
            let session = try await authorize(
                request.metadata,
                requiredScope: .recordingReadOwn
            )
            try validateProtocol(
                request.message.hasProtocol,
                request.message.protocol,
                session: session,
                knownFields: [1, 2, 3]
            )
            let status: HarcHostProcessingStatusResult
            switch request.message.recordingKey {
            case .canonicalRecordingID(let value):
                status = try await service.status(
                    session: session,
                    canonicalRecordingID: try value.domainValue()
                )
            case .originRecordingID(let value):
                status = try await service.status(
                    session: session,
                    originRecordingID: try value.domainValue()
                )
            case nil:
                throw HarcHostError.invalidAuthenticationInput(
                    "processing status key"
                )
            }
            var response = Harc_V1_GetProcessingStatusResponseV1()
            response.protocol = HarcProtocolVersion(
                major: 1,
                minor: session.protocolMinor
            ).protobufV1()
            response.status = try Self.status(
                status,
                protocolMinor: session.protocolMinor
            )
            return ServerResponse(message: response)
        } catch {
            throw HarcPostSessionGRPCErrorMapper.map(error)
        }
    }

    private func authorize(
        _ metadata: Metadata,
        requiredScope: AuthorizationScope
    ) async throws -> HostAuthenticatedSession {
        try await HarcSessionAuthorizationV1.authenticate(
            metadata: metadata,
            authenticator: sessionAuthenticator,
            servedIdentityBinding: servedIdentityBinding,
            requiredScope: requiredScope
        )
    }

    private func validateProtocol(
        _ request: Harc_V1_SubmitOwnArtifactRequestV1,
        session: HostAuthenticatedSession
    ) throws {
        try validateProtocol(
            request.hasProtocol,
            request.protocol,
            session: session,
            knownFields: [1, 2, 3]
        )
    }

    private func validateProtocol(
        _ isPresent: Bool,
        _ wire: Harc_V1_ProtocolVersionV1,
        session: HostAuthenticatedSession,
        knownFields: Set<UInt32>
    ) throws {
        guard isPresent else {
            throw HarcHostError.invalidAuthenticationInput(
                "processing protocol"
            )
        }
        let (version, _) = try compatibility.validate(
            wire,
            knownCriticalFieldNumbers: knownFields
        )
        guard version.major == 1,
              version.minor == session.protocolMinor else {
            throw HarcHostError.invalidAuthenticationInput(
                "processing protocol"
            )
        }
    }

    private static func response(
        _ result: HarcHostProcessingSubmissionResult,
        protocolMinor: UInt16
    ) throws -> Harc_V1_SubmitOwnArtifactResponseV1 {
        var response = Harc_V1_SubmitOwnArtifactResponseV1()
        response.protocol = HarcProtocolVersion(
            major: 1,
            minor: protocolMinor
        ).protobufV1()
        switch result.disposition {
        case .acceptedEdgeArtifact:
            response.disposition =
                .processingSubmissionDispositionAcceptedEdgeArtifact
        case .exactReplay:
            response.disposition = .processingSubmissionDispositionExactReplay
        case .hostProcessingScheduled:
            response.disposition =
                .processingSubmissionDispositionHostProcessingScheduled
        }
        response.status = try status(
            result.status,
            protocolMinor: protocolMinor
        )
        return response
    }

    private static func status(
        _ value: HarcHostProcessingStatusResult,
        protocolMinor: UInt16
    ) throws -> Harc_V1_ProcessingStatusV1 {
        var status = Harc_V1_ProcessingStatusV1()
        status.canonicalRecordingID = Harc_V1_CanonicalRecordingIDV1(
            value.canonicalRecordingID
        )
        status.originRecordingID = Harc_V1_OriginRecordingIDV1(
            value.originRecordingID
        )
        status.processing = Harc_V1_ProcessingDescriptorV1(value.processing)
        status.projection = Harc_V1_ProjectionDescriptorV1(value.projection)
        status.canonicalAudioSha256.value = value.canonicalAudioSHA256
        status.updatedAtUnixMs = try unixMilliseconds(value.updatedAt)
        return status
    }

    private static func unixMilliseconds(_ date: Date) throws -> UInt64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= 0, value <= Double(UInt64.max) else {
            throw HarcHostError.invalidAuthenticationInput("processing time")
        }
        return UInt64(value.rounded(.down))
    }
}
