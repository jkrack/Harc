import CryptoKit
import Darwin
import Foundation
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcStore

public enum HarcHostProcessingSubmissionDisposition: String, Codable, Sendable {
    case acceptedEdgeArtifact
    case exactReplay
    case hostProcessingScheduled
}

public struct HarcHostProcessingStatusResult: Sendable {
    public let canonicalRecordingID: CanonicalRecordingID
    public let originRecordingID: OriginRecordingID
    public let processing: ProcessingDescriptor
    public let projection: ProjectionDescriptor
    public let canonicalAudioSHA256: Data
    public let updatedAt: Date
}

public struct HarcHostProcessingSubmissionResult: Sendable {
    public let disposition: HarcHostProcessingSubmissionDisposition
    public let status: HarcHostProcessingStatusResult
}

/// Authenticates, preserves, and conditionally adopts a producing Mac's exact
/// processing artifact. The device signature proves origin and integrity, not
/// execution; adoption additionally requires an explicit Host compatibility
/// allowlist and complete non-degraded coverage.
public actor HarcHostProcessingArtifactService {
    private let hostStore: HarcHostStore
    private let recordingStore: RecordingStore
    private let sessionService: HarcSessionService
    private let acceptedEngineRevisions: Set<String>
    private let compatibility: HarcProtobufCompatibilityPolicy

    public init(
        hostStore: HarcHostStore,
        recordingStore: RecordingStore,
        sessionService: HarcSessionService,
        acceptedEngineRevisions: Set<String>,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1
    ) {
        self.hostStore = hostStore
        self.recordingStore = recordingStore
        self.sessionService = sessionService
        self.acceptedEngineRevisions = acceptedEngineRevisions
        self.compatibility = compatibility
    }

    public func submit(
        session: HostAuthenticatedSession,
        exactSignedMetadata: Data,
        exactBundle: Data
    ) async throws -> HarcHostProcessingSubmissionResult {
        let authority = try await sessionService.currentDeviceCommandAuthority(
            session: session,
            requiredScope: .processingSubmitOwn
        )
        let acceptedAtMS = try Self.unixMilliseconds(authority.acceptedAt)
        let authenticated = try HarcAuthenticatedSignedObjectV1
            .decodeAndAuthenticate(
                exactSignedMetadata,
                using: authority.registryEntry.devicePublicKey,
                compatibility: compatibility,
                purpose: .initialCommandAcceptance(
                    acceptedAtUnixMilliseconds: acceptedAtMS,
                    currentGrant: try HarcCurrentGrantBindingV1(
                        registryEntry: authority.registryEntry
                    )
                )
            )
        guard case .processingArtifact(let exactMetadata) =
                authenticated.payload else {
            throw HarcHostError.invalidAuthenticationInput(
                "processing artifact type"
            )
        }
        let metadata = exactMetadata.message
        let origin = try metadata.originRecordingID.domainValue()
        guard origin.deviceID == session.context.authenticatedDeviceID,
              let recording = try await recordingStore.fetch(originID: origin),
              recording.deletedAt == nil,
              let recordingID = recording.id,
              let canonicalHash = recording.canonicalPCMHash,
              canonicalHash.rawBytes == metadata.canonicalAudioSha256.value,
              let totalFrames = recording.canonicalPCMFrames else {
            throw HarcHostError.objectOwnershipMismatch
        }
        let validated = try HarcValidatedProcessingSubmissionV1(
            authenticatedMetadata: authenticated,
            exactBundleBytes: exactBundle,
            totalCanonicalFrames: totalFrames,
            supportedRequiredFeatures:
                compatibility.supportedRequiredFeatures,
            versionPolicy: compatibility.versionPolicy
        )
        let operationID = try OperationID(
            Self.uuid(metadata.operationID.value, field: "operationID")
        )
        let artifactID = try Self.uuid(
            metadata.artifactID.value,
            field: "artifactID"
        )
        let paths = try Self.artifactPaths(
            recording: recording,
            artifactID: artifactID
        )
        let effect = HarcProcessingPreparedEffect(
            signedMetadataPath: paths.metadata.path,
            bundlePath: paths.bundle.path,
            signedMetadataSHA256: Data(
                SHA256.hash(data: exactSignedMetadata)
            ),
            bundleSHA256: validated.bundle.exactSHA256
        )
        let preparedEffect = try Self.encoder.encode(effect)
        let issuedAt = try Self.date(
            metadata.issuedAtUnixMs,
            field: "issuedAt"
        )
        let expiresAt = try Self.date(
            metadata.submissionExpiresAtUnixMs,
            field: "expiresAt"
        )
        let preparation = try await hostStore.prepareExternalOperationEffect(
            context: session.context,
            requiredScope: .processingSubmitOwn,
            messageType: HarcSignedMessageTypeV1.processingArtifact.rawValue,
            operationID: operationID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            exactRequestBytes: exactSignedMetadata,
            preparedEffect: preparedEffect
        )
        if case .alreadyApplied(let bytes) = preparation {
            _ = try Self.decoder.decode(
                HarcProcessingAppliedResult.self,
                from: bytes
            )
            return HarcHostProcessingSubmissionResult(
                disposition: .exactReplay,
                status: try await status(
                    session: session,
                    originRecordingID: origin
                )
            )
        }

        try Self.persistExact(exactSignedMetadata, at: paths.metadata)
        try Self.persistExact(exactBundle, at: paths.bundle)

        let acceptsEdge = acceptedEngineRevisions.contains(
            metadata.engineRevision
        ) && metadata.coverage.degradedRanges.isEmpty
            && metadata.coverage.failedRanges.isEmpty
        let disposition: HarcHostProcessingSubmissionDisposition
        if acceptsEdge,
           let transcript = validated.bundle.entries.compactMap({ entry
                -> Harc_V1_TranscriptArtifactV1? in
               guard case .transcript(_, let value) = entry else { return nil }
               return value
           }).first {
            let text = transcript.utterances.map(\.text)
                .joined(separator: "\n\n")
            try await recordingStore.applyAcceptedEdgeTranscript(
                recordingID: recordingID,
                text: text,
                modelID: metadata.engineRevision,
                now: authority.acceptedAt
            )
            disposition = .acceptedEdgeArtifact
        } else {
            disposition = .hostProcessingScheduled
        }

        let applied = HarcProcessingAppliedResult(disposition: disposition)
        let resultBytes = try Self.encoder.encode(applied)
        let key = try HostOperationReplayKey(
            libraryID: session.context.libraryID,
            hostAuthorityID: session.context.hostAuthorityID,
            messageType: HarcSignedMessageTypeV1.processingArtifact.rawValue,
            signer: .device(session.context.authenticatedDeviceID),
            operationID: operationID
        )
        _ = try await hostStore.markPreparedOperationApplied(
            key: key,
            exactRequestBytes: exactSignedMetadata,
            preparedEffect: preparedEffect,
            originalResult: resultBytes
        )
        return HarcHostProcessingSubmissionResult(
            disposition: disposition,
            status: try await status(
                session: session,
                originRecordingID: origin
            )
        )
    }

    public func status(
        session: HostAuthenticatedSession,
        originRecordingID: OriginRecordingID
    ) async throws -> HarcHostProcessingStatusResult {
        _ = try await sessionService.currentDeviceCommandAuthority(
            session: session,
            requiredScope: .recordingReadOwn
        )
        guard originRecordingID.deviceID
                == session.context.authenticatedDeviceID,
              let recording = try await recordingStore.fetch(
                originID: originRecordingID
              ),
              let hash = recording.canonicalPCMHash else {
            throw HarcHostError.objectOwnershipMismatch
        }
        return HarcHostProcessingStatusResult(
            canonicalRecordingID: recording.canonicalID,
            originRecordingID: originRecordingID,
            processing: recording.processing,
            projection: recording.projection,
            canonicalAudioSHA256: hash.rawBytes,
            updatedAt: recording.updatedAt
        )
    }

    public func status(
        session: HostAuthenticatedSession,
        canonicalRecordingID: CanonicalRecordingID
    ) async throws -> HarcHostProcessingStatusResult {
        _ = try await sessionService.currentDeviceCommandAuthority(
            session: session,
            requiredScope: .recordingReadOwn
        )
        guard let recording = try await recordingStore.fetch(
                canonicalID: canonicalRecordingID
              ),
              let origin = recording.originID,
              origin.deviceID == session.context.authenticatedDeviceID,
              let hash = recording.canonicalPCMHash else {
            throw HarcHostError.objectOwnershipMismatch
        }
        return HarcHostProcessingStatusResult(
            canonicalRecordingID: canonicalRecordingID,
            originRecordingID: origin,
            processing: recording.processing,
            projection: recording.projection,
            canonicalAudioSHA256: hash.rawBytes,
            updatedAt: recording.updatedAt
        )
    }

    private static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.outputFormatting = [.sortedKeys]
        return value
    }()
    private static let decoder = JSONDecoder()

    private static func artifactPaths(
        recording: Recording,
        artifactID: UUID
    ) throws -> (metadata: URL, bundle: URL) {
        let root = URL(fileURLWithPath: recording.wavPath)
            .deletingLastPathComponent()
            .appendingPathComponent(".harc-processing", isDirectory: true)
            .appendingPathComponent(
                recording.canonicalID.description,
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let name = artifactID.uuidString.lowercased()
        return (
            root.appendingPathComponent("\(name).harcso"),
            root.appendingPathComponent("\(name).harcpb")
        )
    }

    private static func persistExact(_ data: Data, at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url, options: .mappedIfSafe) == data else {
                throw HarcHostError.provenanceSidecarConflict
            }
            return
        }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporary.path
        )
        let temporaryFD = Darwin.open(
            temporary.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard temporaryFD >= 0 else {
            throw HarcHostError.stagingIO(
                "Could not open a processing sidecar for synchronization."
            )
        }
        defer { Darwin.close(temporaryFD) }
        guard fsync(temporaryFD) == 0 else {
            throw HarcHostError.stagingIO(
                "Could not synchronize a processing sidecar."
            )
        }
        try FileManager.default.moveItem(at: temporary, to: url)
        let directoryFD = Darwin.open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryFD >= 0 else {
            throw HarcHostError.stagingIO(
                "Could not open the processing sidecar directory."
            )
        }
        defer { Darwin.close(directoryFD) }
        guard fsync(directoryFD) == 0 else {
            throw HarcHostError.stagingIO(
                "Could not synchronize the processing sidecar directory."
            )
        }
    }

    private static func uuid(_ bytes: Data, field: String) throws -> UUID {
        guard bytes.count == 16 else {
            throw HarcHostError.invalidAuthenticationInput(field)
        }
        let values = [UInt8](bytes)
        return UUID(uuid: (
            values[0], values[1], values[2], values[3],
            values[4], values[5], values[6], values[7],
            values[8], values[9], values[10], values[11],
            values[12], values[13], values[14], values[15]
        ))
    }

    private static func unixMilliseconds(_ date: Date) throws -> UInt64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= 0, value <= Double(UInt64.max) else {
            throw HarcHostError.invalidAuthenticationInput("time")
        }
        return UInt64(value.rounded(.down))
    }

    private static func date(_ value: UInt64, field: String) throws -> Date {
        let seconds = Double(value) / 1_000
        guard seconds.isFinite else {
            throw HarcHostError.invalidAuthenticationInput(field)
        }
        return Date(timeIntervalSince1970: seconds)
    }
}

private struct HarcProcessingPreparedEffect: Codable {
    let signedMetadataPath: String
    let bundlePath: String
    let signedMetadataSHA256: Data
    let bundleSHA256: Data
}

private struct HarcProcessingAppliedResult: Codable {
    let disposition: HarcHostProcessingSubmissionDisposition
}
