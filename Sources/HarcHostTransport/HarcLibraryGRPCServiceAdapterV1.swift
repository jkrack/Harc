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
        _ = try await authorize(request.metadata, requiredScope: nil)
        throw RPCError(
            code: .unimplemented,
            message: "Canonical audio streaming is not available in this build."
        )
    }

    public func searchMetadata(
        request: ServerRequest<Harc_V1_SearchMetadataRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_SearchMetadataResponseV1> {
        _ = try await authorize(
            request.metadata,
            requiredScope: .libraryMetadataRead
        )
        throw RPCError(code: .unimplemented, message: "Metadata search is not available in this build.")
    }

    public func searchTranscripts(
        request: ServerRequest<Harc_V1_SearchTranscriptsRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_SearchTranscriptsResponseV1> {
        _ = try await authorize(
            request.metadata,
            requiredScope: .libraryTranscriptRead
        )
        throw RPCError(code: .unimplemented, message: "Transcript search is not available in this build.")
    }

    public func applyMetadataMutation(
        request: ServerRequest<Harc_V1_ApplyMetadataMutationRequestV1>,
        context: ServerContext
    ) async throws -> ServerResponse<Harc_V1_ApplyMetadataMutationResponseV1> {
        _ = try await authorize(
            request.metadata,
            requiredScope: .libraryMetadataWrite
        )
        throw RPCError(code: .unimplemented, message: "Remote metadata mutation is not available in this build.")
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
}
