import Foundation
import GRPCCore
import HarcDomain
import HarcHost
import HarcIdentity
import HarcProtocol
import HarcTransfer

protocol HarcRecordingTransferRPCApplication: Sendable {
    func beginUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        request: BeginHostUploadRequest
    ) async throws -> BeginHostUploadDisposition

    func declareChunks(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256,
        descriptors: [LogicalChunkDescriptor]
    ) async throws -> ChunkDeclarationDisposition

    func uploadChunk(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256,
        chunkIndex: UInt32,
        claimedChunkID: ChunkID,
        declaredEncodedLength: UInt64,
        claimedEncodedSHA256: EncodedChunkSHA256,
        body: HostChunkBody
    ) async throws -> StagedChunkDisposition

    func reconcileUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        expectedUploadProfileSHA256: UploadProfileSHA256
    ) async throws -> UploadReconciliation

    func commitUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256,
        exactSignedManifestBytes: Data
    ) async throws -> HostCanonicalCommitDisposition

    func abandonUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256
    ) async throws -> HostAbandonUploadResult

    func getRecordingStatus(
        context: AuthenticatedDeviceContext,
        key: HostRecordingStatusKey
    ) async throws -> HostRecordingStatusResult

    func mintBackgroundCapability(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        request: HostBackgroundCapabilityMintRequest
    ) async throws -> HostBackgroundCapabilityMintResult
}

extension HostRecordingTransferService: HarcRecordingTransferRPCApplication {}

/// Authenticated gRPC Swift 2 edge for resumable recording transfer.
public struct HarcRecordingTransferGRPCServiceAdapterV1:
    Harc_V1_RecordingTransferService.ServiceProtocol, Sendable
{
    static let maximumHostBodyFragmentBytes = 256 * 1_024
    static let maximumIdleReauthenticationInterval: Duration = .seconds(1)

    private let application: any HarcRecordingTransferRPCApplication
    private let sessionAuthenticator: any HarcSessionCredentialAuthenticating
    private let capabilityPolicy: HarcCapabilityPolicyV1
    private let servedIdentityBinding: HarcGRPCServedIdentityBinding
    private let compatibility: HarcProtobufCompatibilityPolicy
    private let idleReauthenticationInterval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    init(
        service: HostRecordingTransferService,
        sessionService: HarcSessionService,
        capabilityPolicy: HarcCapabilityPolicyV1,
        servedIdentityBinding: HarcGRPCServedIdentityBinding
    ) {
        self.init(
            application: service,
            sessionAuthenticator: sessionService,
            capabilityPolicy: capabilityPolicy,
            servedIdentityBinding: servedIdentityBinding,
            compatibility: capabilityPolicy.compatibility
        )
    }

    init(
        application: any HarcRecordingTransferRPCApplication,
        sessionAuthenticator: any HarcSessionCredentialAuthenticating,
        capabilityPolicy: HarcCapabilityPolicyV1,
        servedIdentityBinding: HarcGRPCServedIdentityBinding,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1,
        idleReauthenticationInterval: Duration = .seconds(1),
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(
            idleReauthenticationInterval > .zero
                && idleReauthenticationInterval
                    <= Self.maximumIdleReauthenticationInterval
        )
        self.application = application
        self.sessionAuthenticator = sessionAuthenticator
        self.capabilityPolicy = capabilityPolicy
        self.servedIdentityBinding = servedIdentityBinding
        self.compatibility = compatibility
        self.idleReauthenticationInterval = idleReauthenticationInterval
        self.sleep = sleep
        self.now = now
    }

    public func beginUpload(
        request: ServerRequest<Harc_V1_BeginUploadRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_BeginUploadResponseV1> {
        try await beginUpload(request: request)
    }

    public func declareChunks(
        request: ServerRequest<Harc_V1_DeclareChunksRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_DeclareChunksResponseV1> {
        try await declareChunks(request: request)
    }

    public func uploadChunks(
        request: StreamingServerRequest<Harc_V1_UploadChunkRequestV1>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Harc_V1_UploadChunkResponseV1> {
        try await uploadChunks(request: request)
    }

    public func reconcileUpload(
        request: ServerRequest<Harc_V1_ReconcileUploadRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_ReconcileUploadResponseV1> {
        try await reconcileUpload(request: request)
    }

    public func commitUpload(
        request: ServerRequest<Harc_V1_CommitUploadRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_CommitUploadResponseV1> {
        try await commitUpload(request: request)
    }

    public func abandonUpload(
        request: ServerRequest<Harc_V1_AbandonUploadRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_AbandonUploadResponseV1> {
        try await abandonUpload(request: request)
    }

    public func getRecordingStatus(
        request: ServerRequest<Harc_V1_GetRecordingStatusRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_GetRecordingStatusResponseV1> {
        try await getRecordingStatus(request: request)
    }

    public func mintBackgroundCapability(
        request: ServerRequest<Harc_V1_MintBackgroundCapabilityRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_MintBackgroundCapabilityResponseV1> {
        try await mintBackgroundCapability(request: request)
    }

    func beginUpload(
        request: ServerRequest<Harc_V1_BeginUploadRequestV1>
    ) async throws -> ServerResponse<Harc_V1_BeginUploadResponseV1> {
        do {
            let authorization = try await authorize(metadata: request.metadata)
            let validated = try HarcValidatedBeginUploadRequestV1(
                request.message,
                compatibility: compatibility
            )
            try requireRequestProtocol(
                validated.protocolVersion,
                authorization: authorization
            )
            try requireBeginOwnership(
                validated,
                session: authorization.session
            )
            let disposition = try await application.beginUpload(
                context: authorization.session.context,
                sessionCapabilities: authorization.capabilities,
                request: BeginHostUploadRequest(
                    uploadID: validated.uploadID,
                    originRecordingID: validated.originRecordingID,
                    frozenProfile: validated.frozenProfile,
                    beganAt: now()
                )
            )
            return ServerResponse(
                message: try HarcRecordingTransferGRPCProjectionV1.beginUpload(
                    disposition,
                    request: validated
                )
            )
        } catch {
            throw HarcPostSessionGRPCErrorMapper.map(error)
        }
    }

    func declareChunks(
        request: ServerRequest<Harc_V1_DeclareChunksRequestV1>
    ) async throws -> ServerResponse<Harc_V1_DeclareChunksResponseV1> {
        do {
            let authorization = try await authorize(metadata: request.metadata)
            let validated = try HarcValidatedDeclareChunksRequestV1(
                request.message,
                compatibility: compatibility
            )
            try requireRequestProtocol(
                validated.protocolVersion,
                authorization: authorization
            )
            let disposition = try await application.declareChunks(
                context: authorization.session.context,
                sessionCapabilities: authorization.capabilities,
                uploadID: validated.uploadID,
                generation: validated.generation,
                expectedUploadProfileSHA256: validated.uploadProfileSHA256,
                descriptors: validated.descriptors
            )
            return ServerResponse(
                message: try HarcRecordingTransferGRPCProjectionV1.declareChunks(
                    disposition,
                    request: validated
                )
            )
        } catch {
            throw HarcPostSessionGRPCErrorMapper.map(error)
        }
    }

    func uploadChunks(
        request: StreamingServerRequest<Harc_V1_UploadChunkRequestV1>
    ) async throws -> StreamingServerResponse<Harc_V1_UploadChunkResponseV1> {
        do {
            _ = try await authorize(metadata: request.metadata)
            return StreamingServerResponse(metadata: [:]) { writer in
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await message in request.messages {
                                let authorization = try await self.authorize(
                                    metadata: request.metadata
                                )
                                let validated = try
                                    HarcValidatedUploadChunkRequestV1(
                                        message,
                                        compatibility: self.compatibility
                                    )
                                try self.requireRequestProtocol(
                                    validated.protocolVersion,
                                    authorization: authorization
                                )
                                let disposition = try await self.application.uploadChunk(
                                    context: authorization.session.context,
                                    sessionCapabilities: authorization.capabilities,
                                    uploadID: validated.uploadID,
                                    generation: validated.generation,
                                    expectedUploadProfileSHA256:
                                        validated.uploadProfileSHA256,
                                    chunkIndex: validated.chunkIndex,
                                    claimedChunkID: validated.chunkID,
                                    declaredEncodedLength:
                                        validated.encodedByteLength,
                                    claimedEncodedSHA256: validated.encodedSHA256,
                                    body: Self.hostChunkBody(
                                        validated.encodedChunk
                                    )
                                )
                                try await writer.write(
                                    try HarcRecordingTransferGRPCProjectionV1
                                        .uploadChunk(
                                            disposition,
                                            protocolVersion:
                                                validated.protocolVersion
                                        )
                                )
                            }
                        }
                        group.addTask {
                            while !Task.isCancelled {
                                try await self.sleep(
                                    self.idleReauthenticationInterval
                                )
                                _ = try await self.authorize(
                                    metadata: request.metadata
                                )
                            }
                        }
                        _ = try await group.next()
                        group.cancelAll()
                    }
                    return [:]
                } catch {
                    throw HarcPostSessionGRPCErrorMapper.map(error)
                }
            }
        } catch {
            throw HarcPostSessionGRPCErrorMapper.map(error)
        }
    }

    func reconcileUpload(
        request: ServerRequest<Harc_V1_ReconcileUploadRequestV1>
    ) async throws -> ServerResponse<Harc_V1_ReconcileUploadResponseV1> {
        do {
            let authorization = try await authorize(metadata: request.metadata)
            let validated = try HarcValidatedReconcileUploadRequestV1(
                request.message,
                compatibility: compatibility
            )
            try requireRequestProtocol(
                validated.protocolVersion,
                authorization: authorization
            )
            let reconciliation = try await application.reconcileUpload(
                context: authorization.session.context,
                sessionCapabilities: authorization.capabilities,
                uploadID: validated.uploadID,
                expectedUploadProfileSHA256: validated.uploadProfileSHA256
            )
            return ServerResponse(
                message: try Harc_V1_ReconcileUploadResponseV1(
                    reconciliation,
                    protocolVersion: validated.protocolVersion
                )
            )
        } catch {
            throw HarcPostSessionGRPCErrorMapper.map(error)
        }
    }

    func commitUpload(
        request: ServerRequest<Harc_V1_CommitUploadRequestV1>
    ) async throws -> ServerResponse<Harc_V1_CommitUploadResponseV1> {
        do {
            let authorization = try await authorize(metadata: request.metadata)
            let validated = try HarcValidatedCommitUploadRequestV1(
                request.message,
                compatibility: compatibility
            )
            try requireRequestProtocol(
                validated.protocolVersion,
                authorization: authorization
            )
            let disposition = try await application.commitUpload(
                context: authorization.session.context,
                sessionCapabilities: authorization.capabilities,
                uploadID: validated.uploadID,
                generation: validated.generation,
                expectedUploadProfileSHA256: validated.uploadProfileSHA256,
                exactSignedManifestBytes:
                    validated.exactSignedRecordingManifest
            )
            return ServerResponse(
                message: HarcRecordingTransferGRPCProjectionV1.commitUpload(
                    disposition,
                    protocolVersion: validated.protocolVersion
                )
            )
        } catch {
            throw HarcPostSessionGRPCErrorMapper.map(error)
        }
    }

    func abandonUpload(
        request: ServerRequest<Harc_V1_AbandonUploadRequestV1>
    ) async throws -> ServerResponse<Harc_V1_AbandonUploadResponseV1> {
        do {
            let authorization = try await authorize(metadata: request.metadata)
            let validated = try HarcValidatedAbandonUploadRequestV1(
                request.message,
                compatibility: compatibility
            )
            try requireRequestProtocol(
                validated.protocolVersion,
                authorization: authorization
            )
            let result = try await application.abandonUpload(
                context: authorization.session.context,
                sessionCapabilities: authorization.capabilities,
                uploadID: validated.uploadID,
                generation: validated.generation,
                expectedUploadProfileSHA256: validated.uploadProfileSHA256
            )
            return ServerResponse(
                message: try HarcRecordingTransferGRPCProjectionV1.abandonUpload(
                    result,
                    protocolVersion: validated.protocolVersion
                )
            )
        } catch {
            throw HarcPostSessionGRPCErrorMapper.map(error)
        }
    }

    func getRecordingStatus(
        request: ServerRequest<Harc_V1_GetRecordingStatusRequestV1>
    ) async throws -> ServerResponse<Harc_V1_GetRecordingStatusResponseV1> {
        do {
            let authorization = try await authorize(metadata: request.metadata)
            let validated = try HarcValidatedGetRecordingStatusRequestV1(
                request.message,
                compatibility: compatibility
            )
            try requireRequestProtocol(
                validated.protocolVersion,
                authorization: authorization
            )
            let key: HostRecordingStatusKey
            switch validated.recordingKey {
            case .uploadID(let uploadID):
                key = .uploadID(uploadID)
            case .originRecordingID(let originRecordingID):
                key = .originRecordingID(originRecordingID)
            }
            let result = try await application.getRecordingStatus(
                context: authorization.session.context,
                key: key
            )
            return ServerResponse(
                message: HarcRecordingTransferGRPCProjectionV1
                    .recordingStatus(
                        result,
                        protocolVersion: validated.protocolVersion
                    )
            )
        } catch {
            throw HarcPostSessionGRPCErrorMapper.map(error)
        }
    }

    func mintBackgroundCapability(
        request: ServerRequest<Harc_V1_MintBackgroundCapabilityRequestV1>
    ) async throws -> ServerResponse<Harc_V1_MintBackgroundCapabilityResponseV1> {
        do {
            let authorization = try await authorize(metadata: request.metadata)
            let validated = try HarcValidatedMintBackgroundCapabilityRequestV1(
                request.message,
                compatibility: compatibility
            )
            try requireRequestProtocol(
                validated.protocolVersion,
                authorization: authorization
            )
            let result = try await application.mintBackgroundCapability(
                context: authorization.session.context,
                sessionCapabilities: authorization.capabilities,
                request: HostBackgroundCapabilityMintRequest(
                    uploadID: validated.uploadID,
                    generation: validated.generation,
                    uploadProfileSHA256: validated.uploadProfileSHA256,
                    batchID: validated.batchID,
                    chunks: validated.chunks.map {
                        HostBackgroundChunkBinding(
                            chunkIndex: $0.chunkIndex,
                            encodedSHA256: $0.encodedSHA256
                        )
                    },
                    exactBatchBodySHA256: validated.exactBatchBodySHA256,
                    exactBatchBodyLength: validated.exactBatchBodyLength,
                    requestedExpiresAt: validated.requestedExpiresAt
                )
            )
            return ServerResponse(
                message: try HarcRecordingTransferGRPCProjectionV1
                    .backgroundCapability(
                        result,
                        protocolVersion: validated.protocolVersion
                    )
            )
        } catch {
            throw HarcPostSessionGRPCErrorMapper.map(error)
        }
    }

    private struct Authorization: Sendable {
        let session: HostAuthenticatedSession
        let capabilities: HostTransferSessionCapabilities
    }

    private func authorize(metadata: Metadata) async throws -> Authorization {
        let session = try await HarcSessionAuthorizationV1
            .authenticateRecordingUpload(
                metadata: metadata,
                authenticator: sessionAuthenticator,
                servedIdentityBinding: servedIdentityBinding
            )
        let validated = try HarcValidatedNegotiatedCapabilitiesV1(
            decoding: session.exactCapabilitiesBytes,
            expectedSHA256: session.capabilitiesSHA256,
            policy: capabilityPolicy
        )
        guard validated.protocolVersion.minor == session.protocolMinor,
              validated.encoding.codec.rawValue == session.selectedCodec,
              validated.encoding.container.rawValue
                == session.selectedContainer else {
            throw HarcProtobufConversionError.inconsistentField(
                "session.negotiatedCapabilities"
            )
        }
        let capabilities = try HostTransferSessionCapabilities(
            exactCapabilitiesSHA256: NegotiatedCapabilitiesSHA256(
                validated.exactSHA256
            ),
            protocolVersion: TransferProtocolVersion(
                major: validated.protocolVersion.major,
                minor: validated.protocolVersion.minor
            ),
            selectedFeatureIDs: try validated.selectedFeatureIDs.map(
                TransferCapabilityID.init
            ),
            descriptorSchemaID: TransferCapabilityID(
                validated.descriptorSchemaID
            ),
            encoding: validated.encoding,
            canonicalFormat: validated.canonicalFormat
        )
        return Authorization(session: session, capabilities: capabilities)
    }

    private func requireBeginOwnership(
        _ request: HarcValidatedBeginUploadRequestV1,
        session: HostAuthenticatedSession
    ) throws {
        guard request.libraryID == session.context.libraryID,
              request.hostAuthorityID == session.context.hostAuthorityID,
              request.producingDeviceID
                == session.context.authenticatedDeviceID,
              request.originRecordingID.deviceID
                == session.context.authenticatedDeviceID else {
            throw HarcHostError.objectOwnershipMismatch
        }
    }

    private func requireRequestProtocol(
        _ requestProtocol: HarcProtocolVersion,
        authorization: Authorization
    ) throws {
        let sessionProtocol = authorization.capabilities.protocolVersion
        guard requestProtocol.major == sessionProtocol.major,
              requestProtocol.minor == sessionProtocol.minor else {
            throw HarcProtobufConversionError.inconsistentField(
                "transfer.protocol"
            )
        }
    }

    private static func hostChunkBody(_ data: Data) -> HostChunkBody {
        var fragments: [Data] = []
        fragments.reserveCapacity(
            (data.count + maximumHostBodyFragmentBytes - 1)
                / maximumHostBodyFragmentBytes
        )
        var offset = 0
        while offset < data.count {
            let end = min(offset + maximumHostBodyFragmentBytes, data.count)
            fragments.append(data.subdata(in: offset ..< end))
            offset = end
        }
        return .fragments(fragments)
    }
}

enum HarcRecordingTransferGRPCProjectionV1 {
    static func beginUpload(
        _ disposition: BeginHostUploadDisposition,
        request: HarcValidatedBeginUploadRequestV1
    ) throws -> Harc_V1_BeginUploadResponseV1 {
        var response = Harc_V1_BeginUploadResponseV1()
        response.protocol = request.protocolVersion.protobufV1()
        response.uploadID = Harc_V1_UploadIDV1(request.uploadID)
        response.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: request.frozenProfile.profileSHA256.rawBytes
        )

        let reconciliation: UploadReconciliation?
        switch disposition {
        case .created(let value):
            response.disposition = .beginUploadDispositionCreated
            reconciliation = value
        case .exactReplay(let value):
            response.disposition = .beginUploadDispositionExactReplay
            reconciliation = value
        case .reopened(let value):
            response.disposition = .beginUploadDispositionReopened
            reconciliation = value
        case .alreadyCommitted(let receipt):
            response.disposition = .beginUploadDispositionAlreadyCommitted
            response.exactExistingReceipt = Harc_V1_ExactSignedObjectV1(receipt)
            reconciliation = nil
        }

        if let reconciliation {
            response.uploadGeneration = reconciliation.generation.rawValue
            response.generationExpiresAtUnixMs = try unixMilliseconds(
                reconciliation.generationExpiresAt,
                field: "beginUpload.generationExpiresAt"
            )
            response.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
                exactBytes: reconciliation.uploadProfileSHA256.rawBytes
            )
            response.reconciliation = try Harc_V1_ReconcileUploadResponseV1(
                reconciliation,
                protocolVersion: request.protocolVersion
            )
        }
        return response
    }

    static func declareChunks(
        _ disposition: ChunkDeclarationDisposition,
        request: HarcValidatedDeclareChunksRequestV1
    ) throws -> Harc_V1_DeclareChunksResponseV1 {
        var response = Harc_V1_DeclareChunksResponseV1()
        response.protocol = request.protocolVersion.protobufV1()
        response.uploadID = Harc_V1_UploadIDV1(request.uploadID)
        response.uploadGeneration = request.generation.rawValue
        switch disposition {
        case .appended(let firstIndex, let count):
            guard let count = UInt32(exactly: count) else {
                throw HarcProtobufConversionError.integerOutOfRange(
                    field: "declareChunks.appendedCount"
                )
            }
            response.disposition = .chunkDeclarationDispositionAppended
            response.firstAppendedIndex = firstIndex
            response.appendedCount = count
        case .exactReplay:
            response.disposition = .chunkDeclarationDispositionExactReplay
        case .closed:
            response.disposition = .chunkDeclarationDispositionClosed
        }
        return response
    }

    static func uploadChunk(
        _ disposition: StagedChunkDisposition,
        protocolVersion: HarcProtocolVersion
    ) throws -> Harc_V1_UploadChunkResponseV1 {
        let acknowledgement: HostDurableChunkAcknowledgement
        switch disposition {
        case .durablyAccepted(let value), .exactReplay(let value):
            acknowledgement = value
        }
        var ack = Harc_V1_ChunkAckV1()
        ack.protocol = protocolVersion.protobufV1()
        ack.uploadID = Harc_V1_UploadIDV1(acknowledgement.uploadID)
        ack.uploadGeneration = acknowledgement.generation.rawValue
        ack.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: acknowledgement.uploadProfileSHA256.rawBytes
        )
        ack.durableChunk = try Harc_V1_DurableChunkV1(
            acknowledgement.durableChunk
        )
        ack.durableAtUnixMs = try unixMilliseconds(
            acknowledgement.durableAt,
            field: "uploadChunk.durableAt"
        )
        var response = Harc_V1_UploadChunkResponseV1()
        response.protocol = protocolVersion.protobufV1()
        response.result = .acknowledgement(ack)
        return response
    }

    static func commitUpload(
        _ disposition: HostCanonicalCommitDisposition,
        protocolVersion: HarcProtocolVersion
    ) -> Harc_V1_CommitUploadResponseV1 {
        var response = Harc_V1_CommitUploadResponseV1()
        response.protocol = protocolVersion.protobufV1()
        switch disposition {
        case .committed(let receipt):
            response.disposition = .commitUploadDispositionCommitted
            response.exactSignedRecordingReceipt =
                Harc_V1_ExactSignedObjectV1(receipt)
        case .exactReplay(let receipt):
            response.disposition = .commitUploadDispositionExactReplay
            response.exactSignedRecordingReceipt =
                Harc_V1_ExactSignedObjectV1(receipt)
        }
        return response
    }

    static func abandonUpload(
        _ result: HostAbandonUploadResult,
        protocolVersion: HarcProtocolVersion
    ) throws -> Harc_V1_AbandonUploadResponseV1 {
        var response = Harc_V1_AbandonUploadResponseV1()
        response.protocol = protocolVersion.protobufV1()
        response.uploadID = Harc_V1_UploadIDV1(result.uploadID)
        switch result.terminalReason {
        case .expired:
            response.terminalReason = .uploadTerminalReasonExpired
        case .abandoned:
            response.terminalReason = .uploadTerminalReasonAbandoned
        case .declarationConflict:
            response.terminalReason =
                .uploadTerminalReasonDeclarationConflict
        case .committed:
            response.terminalReason = .uploadTerminalReasonCommitted
        }
        response.terminalAtUnixMs = try unixMilliseconds(
            result.terminalAt,
            field: "abandonUpload.terminalAt"
        )
        return response
    }

    static func recordingStatus(
        _ result: HostRecordingStatusResult,
        protocolVersion: HarcProtocolVersion
    ) -> Harc_V1_GetRecordingStatusResponseV1 {
        var response = Harc_V1_GetRecordingStatusResponseV1()
        response.protocol = protocolVersion.protobufV1()
        response.uploadID = Harc_V1_UploadIDV1(result.uploadID)
        response.originRecordingID = Harc_V1_OriginRecordingIDV1(
            result.originRecordingID
        )
        switch result.ingestState {
        case .receiving:
            response.ingestState = .recordingIngestStateReceiving
        case .manifestVerified:
            response.ingestState = .recordingIngestStateManifestVerified
        case .assembling:
            response.ingestState = .recordingIngestStateAssembling
        case .audioPublished:
            response.ingestState = .recordingIngestStateAudioPublished
        case .recordingCommitted:
            response.ingestState = .recordingIngestStateRecordingCommitted
        case .receipted:
            response.ingestState = .recordingIngestStateReceipted
        case .processing:
            response.ingestState = .recordingIngestStateProcessing
        case .complete:
            response.ingestState = .recordingIngestStateComplete
        case .failedRecoverable:
            response.ingestState = .recordingIngestStateFailedRecoverable
        case .abandoned:
            response.ingestState = .recordingIngestStateAbandoned
        case .expired:
            response.ingestState = .recordingIngestStateExpired
        case .conflictBlocked:
            response.ingestState = .recordingIngestStateConflictBlocked
        }
        if let processing = result.processing {
            response.processing = Harc_V1_ProcessingDescriptorV1(processing)
        }
        if let canonicalRecordingID = result.canonicalRecordingID {
            response.canonicalRecordingID = Harc_V1_CanonicalRecordingIDV1(
                canonicalRecordingID
            )
        }
        if let canonicalRecordingRevision = result.canonicalRecordingRevision {
            response.canonicalRecordingRevision =
                canonicalRecordingRevision.rawValue
        }
        if let exactRecordingReceipt = result.exactRecordingReceipt {
            response.exactRecordingReceipt = Harc_V1_ExactSignedObjectV1(
                exactRecordingReceipt
            )
        }
        return response
    }

    static func backgroundCapability(
        _ result: HostBackgroundCapabilityMintResult,
        protocolVersion: HarcProtocolVersion
    ) throws -> Harc_V1_MintBackgroundCapabilityResponseV1 {
        var response = Harc_V1_MintBackgroundCapabilityResponseV1()
        response.protocol = protocolVersion.protobufV1()
        response.absoluteUploadURL = result.absoluteUploadURL.absoluteString
        response.opaqueCapabilityCredential = result.opaqueCapabilityCredential
        response.issuedAtUnixMs = try unixMilliseconds(
            result.issuedAt,
            field: "mintBackgroundCapability.issuedAt"
        )
        response.expiresAtUnixMs = try unixMilliseconds(
            result.expiresAt,
            field: "mintBackgroundCapability.expiresAt"
        )
        response.byteCeiling = result.byteCeiling
        response.minimumTransportSetEpoch = result.minimumTransportSetEpoch
        var transportSet = Harc_V1_ExactSignedObjectV1()
        transportSet.framedBytes = result.exactSignedTransportSet
        response.exactSignedTransportSet = transportSet
        response.uploadID = Harc_V1_UploadIDV1(result.uploadID)
        response.uploadGeneration = result.generation.rawValue
        response.batchID = Harc_V1_AudioBatchIDV1(result.batchID)
        response.exactBatchBodySha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: result.exactBatchBodySHA256.rawBytes
        )
        response.httpMethod = result.httpMethod
        response.httpPath = result.httpPath
        response.expiryWasClamped = result.expiryWasClamped
        return response
    }

    private static func unixMilliseconds(
        _ date: Date,
        field: String
    ) throws -> UInt64 {
        let seconds = date.timeIntervalSince1970
        let milliseconds = seconds * 1_000
        guard seconds.isFinite, seconds >= 0,
              milliseconds.isFinite,
              milliseconds <= 9_007_199_254_740_991,
              let result = UInt64(exactly: milliseconds.rounded()),
              Date(timeIntervalSince1970: Double(result) / 1_000) == date else {
            throw HarcProtobufConversionError.lossyConversion(field: field)
        }
        return result
    }
}
