import Foundation
import GRPCCore
import HarcDomain
import HarcHost
import HarcIdentity
import HarcProtocol

/// Authenticated gRPC Swift 2 edge for canonical library snapshots, deltas,
/// and path-free recording detail.
public struct HarcLibraryGRPCServiceAdapterV1:
    Harc_V1_LibraryService.ServiceProtocol, Sendable
{
    static let maximumDecodedPageBytes = 1 * 1_024 * 1_024
    static let defaultSnapshotPageItems = 100

    private let service: HarcHostLibraryService
    private let sessionService: HarcSessionService
    private let sessionAuthenticator: any HarcSessionCredentialAuthenticating
    private let servedIdentityBinding: HarcGRPCServedIdentityBinding
    private let compatibility: HarcProtobufCompatibilityPolicy

    init(
        service: HarcHostLibraryService,
        sessionService: HarcSessionService,
        servedIdentityBinding: HarcGRPCServedIdentityBinding,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) {
        self.service = service
        self.sessionService = sessionService
        self.sessionAuthenticator = sessionService
        self.servedIdentityBinding = servedIdentityBinding
        self.compatibility = compatibility
    }

    public func beginLibrarySnapshot(
        request: ServerRequest<Harc_V1_BeginLibrarySnapshotRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_BeginLibrarySnapshotResponseV1> {
        do {
            let session = try await authorize(
                request.metadata,
                requiredScope: .libraryMetadataRead
            )
            let version = try validateProtocol(
                request.message.hasProtocol,
                request.message.protocol,
                knownFields: [1, 2],
                session: session
            )
            let preferred = request.message.hasPreferredPageSize
                ? Int(request.message.preferredPageSize)
                : Self.defaultSnapshotPageItems
            guard (1 ... HarcHostLibraryService.maximumPageItems)
                .contains(preferred) else {
                throw HarcHostLibraryError.invalidPageLimit
            }
            let started = try await service.beginSnapshot(
                session: session,
                preferredPageSize: preferred
            )
            var response = Harc_V1_BeginLibrarySnapshotResponseV1()
            response.protocol = version.protobufV1()
            response.snapshotAnchor = started.anchor.rawValue
            response.snapshotToken = started.snapshotToken
            response.expiresAtUnixMs = try Self.unixMilliseconds(
                started.expiresAt
            )
            response.recordingCount = started.recordingCount
            response.tombstoneCount = started.tombstoneCount
            return ServerResponse(message: response)
        } catch {
            throw HarcPostSessionGRPCErrorMapper.map(error)
        }
    }

    public func listSnapshotPage(
        request: ServerRequest<Harc_V1_ListSnapshotPageRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_ListSnapshotPageResponseV1> {
        do {
            let session = try await authorize(
                request.metadata,
                requiredScope: .libraryMetadataRead
            )
            let version = try validateProtocol(
                request.message.hasProtocol,
                request.message.protocol,
                knownFields: [1, 2, 3],
                session: session
            )
            guard request.message.snapshotToken.count == 32 else {
                throw HarcProtobufConversionError.invalidLength(
                    field: "listSnapshotPage.snapshotToken",
                    expected: 32,
                    actual: request.message.snapshotToken.count
                )
            }
            let pageToken: Data?
            if request.message.hasPageToken {
                guard !request.message.pageToken.isEmpty,
                      request.message.pageToken.count <= 64 else {
                    throw HarcProtobufConversionError.invalidValue(
                        field: "listSnapshotPage.pageToken"
                    )
                }
                pageToken = request.message.pageToken
            } else {
                pageToken = nil
            }

            var maximumItems = HarcHostLibraryService.maximumPageItems
            while true {
                let page = try await service.listSnapshotPage(
                    session: session,
                    snapshotToken: request.message.snapshotToken,
                    pageToken: pageToken,
                    maximumItems: maximumItems
                )
                let response = try Self.snapshotPage(
                    page,
                    protocolVersion: version
                )
                if try response.serializedData().count
                    <= Self.maximumDecodedPageBytes {
                    return ServerResponse(message: response)
                }
                guard maximumItems > 1 else {
                    throw HarcHostLibraryError.snapshotCapacityExceeded
                }
                maximumItems = max(1, maximumItems / 2)
            }
        } catch {
            throw HarcPostSessionGRPCErrorMapper.map(error)
        }
    }

    public func listChanges(
        request: ServerRequest<Harc_V1_ListChangesRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_ListChangesResponseV1> {
        do {
            let session = try await authorize(
                request.metadata,
                requiredScope: .libraryMetadataRead
            )
            let version = try validateProtocol(
                request.message.hasProtocol,
                request.message.protocol,
                knownFields: [1, 2, 3],
                session: session
            )
            guard (1 ... HarcHostLibraryService.maximumPageItems).contains(
                Int(request.message.limit)
            ) else {
                throw HarcHostLibraryError.invalidPageLimit
            }
            let result = try await service.listChanges(
                session: session,
                after: ChangeCursor(request.message.afterCursor),
                limit: Int(request.message.limit)
            )
            var response = Harc_V1_ListChangesResponseV1()
            response.protocol = version.protobufV1()
            switch result {
            case .page(let changes, let nextCursor):
                response.disposition = .listChangesDispositionPage
                response.changes = try changes.map(Self.protobufChange)
                response.nextCursor = nextCursor.rawValue
            case .fullResyncRequired(let currentCursor):
                response.disposition =
                    .listChangesDispositionFullResyncRequired
                response.nextCursor = currentCursor.rawValue
            }
            guard try response.serializedData().count
                <= Self.maximumDecodedPageBytes else {
                throw HarcHostLibraryError.snapshotCapacityExceeded
            }
            return ServerResponse(message: response)
        } catch {
            throw HarcPostSessionGRPCErrorMapper.map(error)
        }
    }

    public func getRecording(
        request: ServerRequest<Harc_V1_GetRecordingRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_GetRecordingResponseV1> {
        do {
            let initial = try await authorize(
                request.metadata,
                requiredScope: nil
            )
            let version = try validateProtocol(
                request.message.hasProtocol,
                request.message.protocol,
                knownFields: [1, 2, 3],
                session: initial
            )
            guard request.message.hasCanonicalRecordingID else {
                throw HarcProtobufConversionError.missingField(
                    "getRecording.canonicalRecordingID"
                )
            }
            let canonicalID = try request.message.canonicalRecordingID
                .domainValue()
            let requestedFields = try Self.requestedDetailFields(
                request.message.requestedFields
            )
            let candidate = try await service.recording(
                session: initial,
                canonicalID: canonicalID
            )
            let ownsRecording = candidate.summary.originID?.deviceID
                == initial.context.authenticatedDeviceID
            let baseScope: AuthorizationScope = ownsRecording
                ? .recordingReadOwn
                : .libraryMetadataRead
            let authorized = try await authorize(
                request.metadata,
                requiredScope: baseScope
            )
            guard authorized.context == initial.context else {
                throw HarcHostLibraryError.snapshotBindingMismatch
            }

            let requestsTranscriptContent = !ownsRecording
                && requestedFields.contains(where: Self.isTranscriptProtected)
            if requestsTranscriptContent {
                let transcriptAuthorized = try await authorize(
                    request.metadata,
                    requiredScope: .libraryTranscriptRead
                )
                guard transcriptAuthorized.context == initial.context else {
                    throw HarcHostLibraryError.snapshotBindingMismatch
                }
            }
            let projected = try Self.project(
                candidate,
                requestedFields: requestedFields
            )
            var response = Harc_V1_GetRecordingResponseV1()
            response.protocol = version.protobufV1()
            response.recording = try Harc_V1_LibraryRecordingDetailV1(
                projected
            )
            return ServerResponse(message: response)
        } catch {
            throw HarcPostSessionGRPCErrorMapper.map(error)
        }
    }

    public func getAudio(
        request: ServerRequest<Harc_V1_GetAudioRequestV1>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Harc_V1_GetAudioResponseV1> {
        do {
            let initial = try await authorize(
                request.metadata,
                requiredScope: nil
            )
            let version = try validateProtocol(
                request.message.hasProtocol,
                request.message.protocol,
                knownFields: [1, 2, 3, 4, 5],
                session: initial
            )
            guard request.message.hasCanonicalRecordingID else {
                throw HarcProtobufConversionError.missingField(
                    "getAudio.canonicalRecordingID"
                )
            }
            let canonicalID = try request.message.canonicalRecordingID
                .domainValue()
            let revision = try EntityRevision(request.message.expectedRevision)
            guard request.message.representation
                    == .audioRepresentationCanonicalWav else {
                throw HarcProtobufConversionError.unsupportedEnum(
                    field: "getAudio.representation",
                    rawValue: request.message.representation.rawValue
                )
            }
            let candidate = try await service.recording(
                session: initial,
                canonicalID: canonicalID
            )
            let ownsRecording = candidate.summary.originID?.deviceID
                == initial.context.authenticatedDeviceID
            let requiredScope: AuthorizationScope = ownsRecording
                ? .recordingReadOwn
                : .libraryAudioRead
            let authorized = try await authorize(
                request.metadata,
                requiredScope: requiredScope
            )
            guard authorized.context == initial.context else {
                throw HarcHostLibraryError.snapshotBindingMismatch
            }
            let prepared = try await service.prepareAudioDownload(
                session: authorized,
                canonicalID: canonicalID,
                expectedRevision: revision
            )
            let offset = request.message.hasResumeByteOffset
                ? request.message.resumeByteOffset
                : 0
            guard offset <= prepared.descriptor.totalByteLength else {
                throw HarcHostLibraryError.invalidResumeOffset
            }
            let descriptorMessage = try Self.audioDescriptorResponse(
                prepared.descriptor,
                protocolVersion: version
            )
            return StreamingServerResponse(metadata: [:]) { writer in
                do {
                    try await writer.write(descriptorMessage)
                    var nextOffset = offset
                    while nextOffset < prepared.descriptor.totalByteLength {
                        let live = try await authorize(
                            request.metadata,
                            requiredScope: requiredScope
                        )
                        guard live.context == authorized.context else {
                            throw HarcHostLibraryError.snapshotBindingMismatch
                        }
                        guard let bytes = try await prepared.reader.read(
                            at: nextOffset,
                            maximumBytes: 512 * 1_024
                        ), !bytes.isEmpty else {
                            throw HarcHostLibraryError.canonicalAudioChanged
                        }
                        var frame = Harc_V1_AudioDownloadFrameV1()
                        frame.byteOffset = nextOffset
                        frame.data = bytes
                        var response = Harc_V1_GetAudioResponseV1()
                        response.protocol = version.protobufV1()
                        response.value = .frame(frame)
                        try await writer.write(response)
                        nextOffset += UInt64(bytes.count)
                    }
                    guard try await prepared.reader.read(
                        at: nextOffset,
                        maximumBytes: 1
                    ) == nil else {
                        throw HarcHostLibraryError.canonicalAudioChanged
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

    public func searchMetadata(
        request: ServerRequest<Harc_V1_SearchMetadataRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_SearchMetadataResponseV1> {
        do {
            let session = try await authorize(
                request.metadata,
                requiredScope: .libraryMetadataRead
            )
            let version = try validateProtocol(
                request.message.hasProtocol,
                request.message.protocol,
                knownFields: [1, 2, 3, 4, 5],
                session: session
            )
            let filter = try Self.metadataFilter(
                request.message.hasFilter ? request.message.filter : nil
            )
            let sort = try Self.metadataSort(request.message.sort)
            let limit = Int(request.message.limit)
            let pageToken = try Self.searchPageToken(
                request.message.hasPageToken,
                request.message.pageToken
            )
            let page = try await service.searchMetadata(
                session: session,
                filter: filter,
                sort: sort,
                limit: limit,
                pageToken: pageToken
            )
            var response = Harc_V1_SearchMetadataResponseV1()
            response.protocol = version.protobufV1()
            response.recordings = try page.recordings.map(
                Harc_V1_LibraryRecordingSummaryV1.init
            )
            if let next = page.nextPageToken { response.nextPageToken = next }
            guard try response.serializedData().count
                <= Self.maximumDecodedPageBytes else {
                throw HarcHostLibraryError.snapshotCapacityExceeded
            }
            return ServerResponse(message: response)
        } catch {
            throw HarcPostSessionGRPCErrorMapper.map(error)
        }
    }

    public func searchTranscripts(
        request: ServerRequest<Harc_V1_SearchTranscriptsRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_SearchTranscriptsResponseV1> {
        do {
            let session = try await authorize(
                request.metadata,
                requiredScope: .libraryTranscriptRead
            )
            let version = try validateProtocol(
                request.message.hasProtocol,
                request.message.protocol,
                knownFields: [1, 2, 3, 4, 5, 6],
                session: session
            )
            let mode = try Self.transcriptMode(request.message.mode)
            let filter = try Self.transcriptFilter(
                request.message.hasFilter ? request.message.filter : nil
            )
            let pageToken = try Self.searchPageToken(
                request.message.hasPageToken,
                request.message.pageToken
            )
            let page = try await service.searchTranscripts(
                session: session,
                query: request.message.query,
                mode: mode,
                filter: filter,
                limit: Int(request.message.limit),
                pageToken: pageToken
            )
            var response = Harc_V1_SearchTranscriptsResponseV1()
            response.protocol = version.protobufV1()
            response.hits = try page.hits.map(Self.protobufTranscriptHit)
            if let next = page.nextPageToken { response.nextPageToken = next }
            guard try response.serializedData().count
                <= Self.maximumDecodedPageBytes else {
                throw HarcHostLibraryError.snapshotCapacityExceeded
            }
            return ServerResponse(message: response)
        } catch {
            throw HarcPostSessionGRPCErrorMapper.map(error)
        }
    }

    public func applyMetadataMutation(
        request: ServerRequest<Harc_V1_ApplyMetadataMutationRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_ApplyMetadataMutationResponseV1> {
        do {
            let session = try await authorize(
                request.metadata,
                requiredScope: .libraryMetadataWrite
            )
            let version = try validateProtocol(
                request.message.hasProtocol,
                request.message.protocol,
                knownFields: [1, 2],
                session: session
            )
            guard request.message.hasExactSignedMetadataMutation,
                  !request.message.exactSignedMetadataMutation.framedBytes.isEmpty else {
                throw HarcProtobufConversionError.missingField(
                    "applyMetadataMutation.exactSignedMetadataMutation"
                )
            }
            let exactBytes = request.message.exactSignedMetadataMutation.framedBytes
            let authority = try await sessionService
                .currentDeviceCommandAuthority(
                    session: session,
                    requiredScope: .libraryMetadataWrite
                )
            let currentGrant = try HarcCurrentGrantBindingV1(
                registryEntry: authority.registryEntry
            )
            let signedObject = try HarcSignedObjectV1.decode(
                exactBytes,
                versionPolicy: compatibility.versionPolicy
            )
            let authenticated: HarcAuthenticatedSignedObjectV1
            do {
                authenticated = try signedObject
                    .authenticateRegisteredPayload(
                        using: authority.registryEntry.devicePublicKey,
                        compatibility: compatibility,
                        purpose: .initialCommandAcceptance(
                            acceptedAtUnixMilliseconds: try Self
                                .unixMilliseconds(authority.acceptedAt),
                            currentGrant: currentGrant
                        )
                    )
            } catch HarcProtocolCodecError.commandExpired {
                // An exact command may already be durably accepted even after
                // its initial-acceptance window. Historical verification still
                // proves its signature and mirrors; the Host replay journal
                // below returns it only if exact bytes were accepted earlier,
                // otherwise it rejects the expired first attempt.
                authenticated = try signedObject
                    .authenticateRegisteredPayload(
                        using: authority.registryEntry.devicePublicKey,
                        compatibility: compatibility,
                        purpose: .historicalEvidence
                    )
            }
            guard case .metadataMutation(let exactMutation) = authenticated.payload else {
                throw HarcProtobufConversionError.invalidValue(
                    field: "applyMetadataMutation.payloadType"
                )
            }
            let wire = exactMutation.message
            let libraryID = try wire.libraryID.domainValue()
            let authorityID = try wire.hostAuthorityID.domainValue()
            let requestingDeviceID = try wire.requestingDeviceID.domainValue()
            let grantID = try wire.grantID.domainValue()
            let grantEpoch = try GrantEpoch(wire.grantEpoch)
            guard libraryID == session.context.libraryID,
                  authorityID == session.context.hostAuthorityID,
                  requestingDeviceID == session.context.authenticatedDeviceID,
                  grantID == session.context.grantID,
                  grantEpoch == session.context.grantEpoch else {
                throw HarcHostError.grantMismatch
            }
            let command = HarcHostMetadataMutationCommand(
                operationID: try wire.operationID.domainValue(),
                issuedAt: try Self.date(unixMilliseconds: wire.issuedAtUnixMs),
                expiresAt: try Self.date(unixMilliseconds: wire.expiresAtUnixMs),
                canonicalID: try wire.canonicalRecordingID.domainValue(),
                expectedRevision: try EntityRevision(wire.expectedRevision),
                mutation: try Self.metadataMutation(wire.mutation),
                exactSignedRequestBytes: exactBytes
            )
            let result = try await service.applyMetadataMutation(
                session: session,
                command: command
            )
            var response = Harc_V1_ApplyMetadataMutationResponseV1()
            response.protocol = version.protobufV1()
            switch result {
            case .applied(let newRevision, let changeCursor):
                var applied = Harc_V1_MetadataMutationAppliedV1()
                applied.newRevision = newRevision.rawValue
                applied.changeCursor = changeCursor.rawValue
                response.result = .applied(applied)
            case .conflict(let currentRevision, let currentValue):
                var conflict = Harc_V1_MetadataMutationConflictV1()
                conflict.currentRevision = currentRevision.rawValue
                conflict.currentValue = Self.protobufMetadataFieldValue(
                    currentValue
                )
                response.result = .conflict(conflict)
            }
            return ServerResponse(message: response)
        } catch {
            throw HarcPostSessionGRPCErrorMapper.map(error)
        }
    }

    public func getSpeakerRecognitionPack(
        request: ServerRequest<Harc_V1_GetSpeakerRecognitionPackRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_GetSpeakerRecognitionPackResponseV1> {
        do {
            let session = try await authorize(
                request.metadata,
                requiredScope: .speakerIdentityRead
            )
            let version = try validateProtocol(
                request.message.hasProtocol,
                request.message.protocol,
                knownFields: [1, 2],
                session: session
            )
            let afterRevision = request.message.hasAfterRevision
                ? try EntityRevision(request.message.afterRevision)
                : nil
            let pack = try await service.speakerRecognitionPack(
                session: session,
                afterRevision: afterRevision
            )
            var response = Harc_V1_GetSpeakerRecognitionPackResponseV1()
            response.protocol = version.protobufV1()
            response.unchanged = pack == nil
            if let pack {
                response.pack = try Harc_V1_SpeakerRecognitionPackV1(pack)
            }
            return ServerResponse(message: response)
        } catch {
            throw HarcPostSessionGRPCErrorMapper.map(error)
        }
    }

    public func submitSpeakerObservation(
        request: ServerRequest<Harc_V1_SubmitSpeakerObservationRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_SubmitSpeakerObservationResponseV1> {
        do {
            let session = try await authorize(
                request.metadata,
                requiredScope: .speakerObservationWrite
            )
            let version = try validateProtocol(
                request.message.hasProtocol,
                request.message.protocol,
                knownFields: [1, 2],
                session: session
            )
            guard request.message.hasObservation else {
                throw HarcProtobufConversionError.missingField(
                    "submitSpeakerObservation.observation"
                )
            }
            let decision = try await service.submitSpeakerObservation(
                session: session,
                observation: request.message.observation.domainValue()
            )
            var response = Harc_V1_SubmitSpeakerObservationResponseV1()
            response.protocol = version.protobufV1()
            response.decision = Harc_V1_SpeakerObservationDecisionV1(decision)
            return ServerResponse(message: response)
        } catch {
            throw HarcPostSessionGRPCErrorMapper.map(error)
        }
    }

    private func authorize(
        _ metadata: Metadata,
        requiredScope: AuthorizationScope?
    ) async throws -> HostAuthenticatedSession {
        try await HarcSessionAuthorizationV1.authenticate(
            metadata: metadata,
            authenticator: sessionAuthenticator,
            servedIdentityBinding: servedIdentityBinding,
            requiredScope: requiredScope
        )
    }

    private func validateProtocol(
        _ isPresent: Bool,
        _ wire: Harc_V1_ProtocolVersionV1,
        knownFields: Set<UInt32>,
        session: HostAuthenticatedSession
    ) throws -> HarcProtocolVersion {
        guard isPresent else {
            throw HarcProtobufConversionError.missingField("library.protocol")
        }
        let (version, _) = try compatibility.validate(
            wire,
            knownCriticalFieldNumbers: knownFields
        )
        guard version.major == 1,
              version.minor == session.protocolMinor else {
            throw HarcProtobufConversionError.inconsistentField(
                "library.protocol"
            )
        }
        return version
    }

    private static func snapshotPage(
        _ page: HarcHostLibrarySnapshotPage,
        protocolVersion: HarcProtocolVersion
    ) throws -> Harc_V1_ListSnapshotPageResponseV1 {
        var response = Harc_V1_ListSnapshotPageResponseV1()
        response.protocol = protocolVersion.protobufV1()
        response.snapshotAnchor = page.anchor.rawValue
        response.items = try page.items.map { item in
            var wire = Harc_V1_SnapshotItemV1()
            switch item {
            case .recording(let summary):
                wire.value = .recording(
                    try Harc_V1_LibraryRecordingSummaryV1(summary)
                )
            case .tombstone(let tombstone):
                wire.value = .tombstone(
                    try Harc_V1_RecordingTombstoneV1(tombstone)
                )
            }
            return wire
        }
        if let nextPageToken = page.nextPageToken {
            response.nextPageToken = nextPageToken
        }
        response.complete = page.complete
        return response
    }

    private static func protobufChange(
        _ change: MaterializedLibraryChange
    ) throws -> Harc_V1_LibraryChangeV1 {
        let value: HarcLibraryChangeValueV1
        switch change.value {
        case .upsert(let summary): value = .upsert(summary)
        case .tombstone(let tombstone): value = .tombstone(tombstone)
        }
        return try HarcValidatedLibraryChangeV1(
            descriptor: change.descriptor,
            value: value
        ).protobufV1
    }

    private static func requestedDetailFields(
        _ fields: [Harc_V1_RecordingDetailFieldV1]
    ) throws -> Set<Harc_V1_RecordingDetailFieldV1> {
        let resolved = fields.isEmpty
            ? [.recordingDetailFieldMetadata]
            : fields
        var result = Set<Harc_V1_RecordingDetailFieldV1>()
        for field in resolved {
            switch field {
            case .recordingDetailFieldMetadata,
                 .recordingDetailFieldTranscript,
                 .recordingDetailFieldSpeakerLabels,
                 .recordingDetailFieldSummary,
                 .recordingDetailFieldActionItems,
                 .recordingDetailFieldNotes,
                 .recordingDetailFieldDiscontinuities:
                guard result.insert(field).inserted else {
                    throw HarcProtobufConversionError.duplicateValue(
                        field: "getRecording.requestedFields"
                    )
                }
            case .recordingDetailFieldUnspecified:
                throw HarcProtobufConversionError.unsupportedEnum(
                    field: "getRecording.requestedFields",
                    rawValue: field.rawValue
                )
            case .UNRECOGNIZED(let rawValue):
                throw HarcProtobufConversionError.unsupportedEnum(
                    field: "getRecording.requestedFields",
                    rawValue: rawValue
                )
            }
        }
        return result
    }

    private static func metadataFilter(
        _ wire: Harc_V1_MetadataSearchFilterV1?
    ) throws -> HarcHostMetadataSearchFilter {
        guard let wire else { return HarcHostMetadataSearchFilter() }
        let title = try wire.hasTitleContains
            ? validatedSearchString(
                wire.titleContains,
                field: "searchMetadata.filter.titleContains",
                maximumBytes: 512
            )
            : nil
        let tagsAll = try validatedUniqueStrings(
            wire.tagsAll,
            field: "searchMetadata.filter.tagsAll",
            maximumCount: 128,
            maximumBytes: 128
        )
        let tagsAny = try validatedUniqueStrings(
            wire.tagsAny,
            field: "searchMetadata.filter.tagsAny",
            maximumCount: 128,
            maximumBytes: 128
        )
        let speakers = try validatedUniqueStrings(
            wire.speakerDisplayNames,
            field: "searchMetadata.filter.speakerDisplayNames",
            maximumCount: 128,
            maximumBytes: 256
        )
        let range = try unixRange(
            wire.hasStartedAt ? wire.startedAt : nil,
            field: "searchMetadata.filter.startedAt"
        )
        var processing: [RecordingProcessingState] = []
        for state in wire.processingStates {
            let decoded = try processingState(state)
            guard !processing.contains(decoded) else {
                throw HarcProtobufConversionError.duplicateValue(
                    field: "searchMetadata.filter.processingStates"
                )
            }
            processing.append(decoded)
        }
        return HarcHostMetadataSearchFilter(
            titleContains: title,
            tagsAll: Set(tagsAll),
            tagsAny: Set(tagsAny),
            startedAtStart: range.start,
            startedAtEnd: range.end,
            speakerDisplayNames: Set(speakers),
            pinned: wire.hasPinned ? wire.pinned : nil,
            processingStates: processing
        )
    }

    private static func metadataSort(
        _ wire: Harc_V1_MetadataSearchSortV1
    ) throws -> HarcHostMetadataSearchSort {
        switch wire {
        case .metadataSearchSortStartedAtDescending:
            return .startedAtDescending
        case .metadataSearchSortStartedAtAscending:
            return .startedAtAscending
        case .metadataSearchSortTitleAscending:
            return .titleAscending
        case .metadataSearchSortUnspecified:
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "searchMetadata.sort",
                rawValue: wire.rawValue
            )
        case .UNRECOGNIZED(let value):
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "searchMetadata.sort",
                rawValue: value
            )
        }
    }

    private static func transcriptFilter(
        _ wire: Harc_V1_TranscriptSearchFilterV1?
    ) throws -> HarcHostTranscriptSearchFilter {
        guard let wire else { return HarcHostTranscriptSearchFilter() }
        let ids = try wire.canonicalRecordingIds.map { try $0.domainValue() }
        guard Set(ids).count == ids.count else {
            throw HarcProtobufConversionError.duplicateValue(
                field: "searchTranscripts.filter.canonicalRecordingIDs"
            )
        }
        let tags = try validatedUniqueStrings(
            wire.tags,
            field: "searchTranscripts.filter.tags",
            maximumCount: 128,
            maximumBytes: 128
        )
        guard Set(wire.speakerIndices).count == wire.speakerIndices.count else {
            throw HarcProtobufConversionError.duplicateValue(
                field: "searchTranscripts.filter.speakerIndices"
            )
        }
        let range = try unixRange(
            wire.hasStartedAt ? wire.startedAt : nil,
            field: "searchTranscripts.filter.startedAt"
        )
        return HarcHostTranscriptSearchFilter(
            canonicalRecordingIDs: Set(ids),
            tags: Set(tags),
            startedAtStart: range.start,
            startedAtEnd: range.end,
            speakerIndices: Set(wire.speakerIndices)
        )
    }

    private static func transcriptMode(
        _ wire: Harc_V1_TranscriptSearchModeV1
    ) throws -> HarcHostTranscriptSearchMode {
        switch wire {
        case .transcriptSearchModeLexical: return .lexical
        case .transcriptSearchModeSemantic: return .semantic
        case .transcriptSearchModeHybrid: return .hybrid
        case .transcriptSearchModeUnspecified:
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "searchTranscripts.mode",
                rawValue: wire.rawValue
            )
        case .UNRECOGNIZED(let value):
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "searchTranscripts.mode",
                rawValue: value
            )
        }
    }

    private static func protobufTranscriptHit(
        _ value: HarcHostTranscriptSearchHit
    ) throws -> Harc_V1_TranscriptSearchHitV1 {
        guard value.score.isFinite else {
            throw HarcProtobufConversionError.invalidValue(
                field: "searchTranscripts.hit.score"
            )
        }
        var wire = Harc_V1_TranscriptSearchHitV1()
        wire.recording = try Harc_V1_LibraryRecordingSummaryV1(value.recording)
        wire.score = value.score
        wire.snippets = value.snippets.map { snippet in
            var result = Harc_V1_TranscriptSearchSnippetV1()
            result.text = snippet.text
            result.frames = Harc_V1_CanonicalFrameRangeV1(snippet.frames)
            if let speaker = snippet.speakerIndex {
                result.speakerIndex = speaker
            }
            return result
        }
        return wire
    }

    private static func audioDescriptorResponse(
        _ value: HarcHostAudioDownloadDescriptor,
        protocolVersion: HarcProtocolVersion
    ) throws -> Harc_V1_GetAudioResponseV1 {
        guard value.contentSHA256.count == 32 else {
            throw HarcProtobufConversionError.invalidLength(
                field: "getAudio.contentSHA256",
                expected: 32,
                actual: value.contentSHA256.count
            )
        }
        var descriptor = Harc_V1_AudioDownloadDescriptorV1()
        descriptor.canonicalRecordingID =
            Harc_V1_CanonicalRecordingIDV1(value.canonicalID)
        descriptor.revision = value.revision.rawValue
        descriptor.representation = .audioRepresentationCanonicalWav
        descriptor.contentType = value.contentType
        descriptor.totalByteLength = value.totalByteLength
        descriptor.contentSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: value.contentSHA256
        )
        descriptor.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(
            value.canonicalFormat
        )
        descriptor.totalCanonicalFrames = value.totalCanonicalFrames
        descriptor.canonicalPcmSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: value.canonicalPCMSHA256.rawBytes
        )
        var response = Harc_V1_GetAudioResponseV1()
        response.protocol = protocolVersion.protobufV1()
        response.value = .descriptor(descriptor)
        return response
    }

    private static func searchPageToken(
        _ isPresent: Bool,
        _ value: Data
    ) throws -> Data? {
        guard isPresent else { return nil }
        guard value.count == 24 else {
            throw HarcProtobufConversionError.invalidLength(
                field: "library.search.pageToken",
                expected: 24,
                actual: value.count
            )
        }
        return value
    }

    private static func validatedUniqueStrings(
        _ values: [String],
        field: String,
        maximumCount: Int,
        maximumBytes: Int
    ) throws -> [String] {
        guard values.count <= maximumCount else {
            throw HarcProtobufConversionError.invalidValue(field: field)
        }
        let normalized = try values.map {
            try validatedSearchString(
                $0,
                field: field,
                maximumBytes: maximumBytes
            )
        }
        guard Set(normalized).count == normalized.count else {
            throw HarcProtobufConversionError.duplicateValue(field: field)
        }
        return normalized
    }

    private static func validatedSearchString(
        _ value: String,
        field: String,
        maximumBytes: Int
    ) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= maximumBytes else {
            throw HarcProtobufConversionError.invalidValue(field: field)
        }
        return normalized
    }

    private static func unixRange(
        _ wire: Harc_V1_UnixTimeRangeV1?,
        field: String
    ) throws -> (start: Date?, end: Date?) {
        guard let wire else { return (nil, nil) }
        let start = wire.hasStartUnixMs
            ? Date(timeIntervalSince1970: Double(wire.startUnixMs) / 1_000)
            : nil
        let end = wire.hasEndUnixMs
            ? Date(timeIntervalSince1970: Double(wire.endUnixMs) / 1_000)
            : nil
        guard start == nil || end == nil || start! <= end! else {
            throw HarcProtobufConversionError.invalidValue(field: field)
        }
        return (start, end)
    }

    private static func processingState(
        _ wire: Harc_V1_RecordingProcessingStateV1
    ) throws -> RecordingProcessingState {
        switch wire {
        case .recordingProcessingStatePending: return .pending
        case .recordingProcessingStateTranscribing: return .transcribing
        case .recordingProcessingStateProjecting: return .projecting
        case .recordingProcessingStateReady: return .ready
        case .recordingProcessingStateDegraded: return .degraded
        case .recordingProcessingStateFailedRecoverable:
            return .failedRecoverable
        case .recordingProcessingStateUnspecified:
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "searchMetadata.filter.processingStates",
                rawValue: wire.rawValue
            )
        case .UNRECOGNIZED(let value):
            throw HarcProtobufConversionError.unsupportedEnum(
                field: "searchMetadata.filter.processingStates",
                rawValue: value
            )
        }
    }

    private static func isTranscriptProtected(
        _ field: Harc_V1_RecordingDetailFieldV1
    ) -> Bool {
        switch field {
        case .recordingDetailFieldTranscript,
             .recordingDetailFieldSpeakerLabels,
             .recordingDetailFieldSummary,
             .recordingDetailFieldActionItems:
            true
        default:
            false
        }
    }

    private static func project(
        _ detail: LibraryRecordingDetail,
        requestedFields: Set<Harc_V1_RecordingDetailFieldV1>
    ) throws -> LibraryRecordingDetail {
        try LibraryRecordingDetail(
            summary: detail.summary,
            transcriptText: requestedFields.contains(
                .recordingDetailFieldTranscript
            ) ? detail.transcriptText : nil,
            speakerLabels: requestedFields.contains(
                .recordingDetailFieldSpeakerLabels
            ) ? detail.speakerLabels : [],
            summaryMarkdown: requestedFields.contains(
                .recordingDetailFieldSummary
            ) ? detail.summaryMarkdown : nil,
            actionItemsMarkdown: requestedFields.contains(
                .recordingDetailFieldActionItems
            ) ? detail.actionItemsMarkdown : nil,
            notesMarkdown: requestedFields.contains(
                .recordingDetailFieldNotes
            ) ? detail.notesMarkdown : nil,
            discontinuities: requestedFields.contains(
                .recordingDetailFieldDiscontinuities
            ) ? detail.discontinuities : []
        )
    }

    private static func unixMilliseconds(_ date: Date) throws -> UInt64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite,
              value >= 0,
              value <= Double(UInt64.max) else {
            throw HarcProtobufConversionError.invalidValue(
                field: "library.date"
            )
        }
        return UInt64(value.rounded(.down))
    }

    private static func date(unixMilliseconds value: UInt64) throws -> Date {
        guard value <= 9_007_199_254_740_991 else {
            throw HarcProtobufConversionError.invalidValue(
                field: "metadataMutation.date"
            )
        }
        let date = Date(timeIntervalSince1970: Double(value) / 1_000)
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw HarcProtobufConversionError.invalidValue(
                field: "metadataMutation.date"
            )
        }
        return date
    }

    private static func metadataMutation(
        _ wire: Harc_V1_MetadataMutationV1.OneOf_Mutation?
    ) throws -> HarcHostMetadataMutation {
        guard let wire else {
            throw HarcProtobufConversionError.missingField(
                "metadataMutation.mutation"
            )
        }
        switch wire {
        case .setTitle(let value):
            return .setTitle(value.hasTitle ? value.title : nil)
        case .replaceTags(let value):
            return .replaceTags(value.tags)
        case .setSpeakerLabel(let value):
            return .setSpeakerLabel(
                index: value.speakerIndex,
                displayName: value.hasDisplayName ? value.displayName : nil
            )
        case .assignSpeakerIdentity(let value):
            return .assignSpeakerIdentity(
                index: value.speakerIndex,
                personID: value.hasPersonID
                    ? try value.personID.domainValue()
                    : nil
            )
        case .setNotesMarkdown(let value):
            return .setNotesMarkdown(
                value.hasMarkdown ? value.markdown : nil
            )
        case .setPinned(let value):
            return .setPinned(value.pinned)
        }
    }

    private static func protobufMetadataFieldValue(
        _ value: HarcHostMetadataFieldValue
    ) -> Harc_V1_MetadataFieldValueV1 {
        var wire = Harc_V1_MetadataFieldValueV1()
        switch value {
        case .title(let value):
            if let value { wire.value = .title(value) }
            wire.isCleared = value == nil
        case .tags(let values):
            var tags = Harc_V1_MetadataTagsValueV1()
            tags.tags = values
            wire.value = .tags(tags)
        case .speakerLabel(let index, let displayName):
            var label = Harc_V1_MetadataSpeakerLabelValueV1()
            label.speakerIndex = index
            if let displayName { label.displayName = displayName }
            wire.value = .speakerLabel(label)
            wire.isCleared = displayName == nil
        case .speakerIdentity(let index, let personID, let displayName):
            var identity = Harc_V1_MetadataSpeakerIdentityValueV1()
            identity.speakerIndex = index
            if let personID { identity.personID = Harc_V1_PersonIDV1(personID) }
            if let displayName { identity.displayName = displayName }
            wire.value = .speakerIdentity(identity)
            wire.isCleared = personID == nil
        case .notesMarkdown(let value):
            if let value { wire.value = .notesMarkdown(value) }
            wire.isCleared = value == nil
        case .pinned(let value):
            wire.value = .pinned(value)
        }
        return wire
    }
}
