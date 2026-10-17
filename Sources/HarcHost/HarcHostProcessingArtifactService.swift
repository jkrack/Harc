import CryptoKit
import Darwin
import Foundation
import HarcCore
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
    public let selectedEdgeBundleSHA256: Data?
    public let hostSpeakerOutcome: HostSpeakerProcessingOutcome?
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
            && Self.canProjectSpeakerInformation(validated.bundle.entries)
        let disposition: HarcHostProcessingSubmissionDisposition
        if acceptsEdge,
           let transcript = validated.bundle.entries.compactMap({ entry
                -> Harc_V1_TranscriptArtifactV1? in
               guard case .transcript(_, let value) = entry else { return nil }
               return value
           }).first {
            let text = Self.acceptedTranscriptText(transcript)
            let projected = try Self.acceptedTranscriptProjection(validated, recording: recording)
            try await recordingStore.applyAcceptedEdgeTranscript(
                recordingID: recordingID,
                text: text,
                modelID: metadata.engineRevision,
                structuredTranscriptData: projected.data, clusterMap: projected.clusterMap,
                artifactSource: try SelectedEdgeArtifactSource(signedMetadataURL: paths.metadata,
                    bundleURL: paths.bundle, signedMetadataSHA256: effect.signedMetadataSHA256,
                    bundleSHA256: effect.bundleSHA256),
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

    /// Bound observations use only the Host's selected artifact. The transport
    /// must negotiate this endpoint separately from the legacy unbound request.
    public func submitBoundSpeakerObservation(session: HostAuthenticatedSession,
        observation: BoundSpeakerEmbeddingObservation) async throws -> SpeakerObservationDecision {
        let authority = try await sessionService.currentDeviceCommandAuthority(
            session: session, requiredScope: .speakerObservationWrite)
        guard try await recordingStore.libraryMetadata().libraryID == session.context.libraryID,
              let recording = try await recordingStore.fetch(canonicalID: observation.evidence.canonicalRecordingID),
              recording.deletedAt == nil, let recordingID = recording.id,
              let origin = recording.originID,
              origin.deviceID == session.context.authenticatedDeviceID,
              observation.evidence.producerDeviceID == origin.deviceID,
              let pcmHash = recording.canonicalPCMHash, let frames = recording.canonicalPCMFrames,
              let source = try await recordingStore.selectedEdgeArtifactSource(recordingID: recordingID) else {
            throw HarcHostError.objectOwnershipMismatch
        }
        let metadataBytes = try Self.readBoundedArtifact(at: source.signedMetadataURL,
            maximumBytes: HarcProtocolLimits.signedObjectBytes)
        let bundleBytes = try Self.readBoundedArtifact(at: source.bundleURL,
            maximumBytes: HarcProcessingBundleV1.maximumExactBytes)
        let authenticated = try HarcAuthenticatedSignedObjectV1.decodeAndAuthenticate(metadataBytes,
            using: authority.registryEntry.devicePublicKey, compatibility: compatibility, purpose: .historicalEvidence)
        let retained = try HarcValidatedRetainedProcessingArtifactV1(authenticatedMetadata: authenticated,
            exactBundleBytes: bundleBytes, selectedSignedMetadataSHA256: source.signedMetadataSHA256,
            selectedBundleSHA256: source.bundleSHA256, totalCanonicalFrames: frames,
            supportedRequiredFeatures: compatibility.supportedRequiredFeatures, versionPolicy: compatibility.versionPolicy)
        guard try retained.metadata.message.libraryID.domainValue() == session.context.libraryID,
              try retained.metadata.message.hostAuthorityID.domainValue() == session.context.hostAuthorityID else {
            throw HarcHostError.objectOwnershipMismatch
        }
        let validated = try HarcValidatedSpeakerEvidenceV1(observation, retainedArtifact: retained,
            canonicalRecordingID: recording.canonicalID, originRecordingID: origin,
            canonicalPCMHash: pcmHash, currentArtifactSHA256: source.bundleSHA256)
        // Recheck current permission after file IO, before the Store mutation.
        _ = try await sessionService.currentDeviceCommandAuthority(session: session, requiredScope: .speakerObservationWrite)
        return try await recordingStore.submitSelectedEdgeSpeakerObservation(validated.value,
            validatedClusterMap: validated.clusterMap, selectedArtifactSource: source,
            from: session.context.authenticatedDeviceID, at: authority.acceptedAt)
    }

    static func readBoundedArtifact(at url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0, maximumBytes < Int.max else {
            throw HarcHostError.invalidAuthenticationInput("artifact read limit")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var result = Data()
        while true {
            let block = try autoreleasepool {
                try file.read(upToCount: min(65_536, maximumBytes - result.count + 1)) ?? Data()
            }
            if block.isEmpty { return result }
            guard block.count <= maximumBytes - result.count else {
                throw HarcHostError.invalidAuthenticationInput("processing artifact exceeds read limit")
            }
            result.append(block)
        }
    }

    /// V1 Client cluster identifiers are not bound to Host speaker indices.
    /// Retain the signed bundle, but use Host processing when adopting it would
    /// discard speaker information or reuse an unrelated Host identity.
    static func canProjectSpeakerInformation(_ entries: [HarcProcessingBundleEntryV1]) -> Bool {
        entries.allSatisfy { entry in
            switch entry {
            case .diarization(_, let diarization):
                return diarization.turns.isEmpty
            case .transcript(_, let transcript):
                return transcript.utterances.allSatisfy { utterance in
                    !utterance.hasLocalSpeakerID && !utterance.words.contains { $0.hasLocalSpeakerID }
                }
            default:
                return true
            }
        }
    }

    /// Projection and mapping are derived together from the authenticated bundle.
    /// The caller must atomically select both before permitting remote name projection.
    static func acceptedTranscriptProjection(
        _ submission: HarcValidatedProcessingSubmissionV1, recording: Recording
    ) throws -> (data: Data, clusterMap: SpeakerClusterMap) {
        let map = try submission.speakerClusterMap(canonicalRecordingID: recording.canonicalID)
        guard recording.canonicalPCMHash == map.canonicalPCMHash,
              let transcript = submission.bundle.entries.compactMap({ entry -> Harc_V1_TranscriptArtifactV1? in
                  guard case .transcript(_, let value) = entry else { return nil }
                  return value
              }).first else {
            throw HarcProtobufConversionError.inconsistentField("speakerProjection.recordingOrTranscript")
        }
        let turns = submission.bundle.entries.flatMap { entry -> [Harc_V1_SpeakerTurnV1] in
            guard case .diarization(_, let value) = entry else { return [] }
            return value.turns
        }
        return (try acceptedTranscriptData(transcript, recording: recording, clusterMap: map, turns: turns), map)
    }

    /// Local JSON projection of a validated artifact. This is the saved
    /// SessionTranscript schema, not a network DTO; paths come only from the
    /// Host recording. Keep its decode contract covered by application tests.
    static func acceptedTranscriptData(
        _ transcript: Harc_V1_TranscriptArtifactV1, recording: Recording,
        clusterMap: SpeakerClusterMap? = nil, turns: [Harc_V1_SpeakerTurnV1] = []
    ) throws -> Data {
        if let clusterMap {
            guard clusterMap.canonicalRecordingID == recording.canonicalID,
                  clusterMap.canonicalPCMHash == recording.canonicalPCMHash else {
                throw HarcProtobufConversionError.inconsistentField("speakerProjection.recording")
            }
        } else if !turns.isEmpty || transcript.utterances.contains(where: {
            $0.hasLocalSpeakerID || $0.words.contains(where: { $0.hasLocalSpeakerID })
        }) {
            throw HarcProtobufConversionError.inconsistentField("speakerProjection.missingClusterMap")
        }
        let indices = Dictionary(uniqueKeysWithValues: (clusterMap?.localClusterIDs ?? []).enumerated().map { ($0.element, $0.offset) })
        func attribution(_ id: String) throws -> [String: Any] {
            guard let index = indices[id] else {
                throw HarcProtobufConversionError.inconsistentField("speakerProjection.unknownCluster")
            }
            return ["speakerIndex": index]
        }
        func milliseconds(_ frame: UInt64, roundUp: Bool = false) throws -> Int {
            let value = frame / 16 + (roundUp && frame % 16 != 0 ? 1 : 0)
            guard let result = Int(exactly: value) else {
                throw HarcProtocolCodecError.numericOverflow(field: "transcript.frameTime")
            }
            return result
        }
        var words: [[String: Any]] = []
        let utterances: [[String: Any]] = try transcript.utterances.map { utterance in
            var parent: [String: Any] = ["text": utterance.text,
                "startMs": try milliseconds(utterance.startFrame),
                "endMs": try milliseconds(utterance.endFrameExclusive, roundUp: true)]
            if utterance.hasLocalSpeakerID { parent["speakerAttribution"] = try attribution(utterance.localSpeakerID) }
            parent["words"] = try utterance.words.map { word -> [String: Any] in
                var projected: [String: Any] = ["text": word.text, "startMs": try milliseconds(word.startFrame),
                    "endMs": try milliseconds(word.endFrameExclusive, roundUp: true)]
                if word.hasLocalSpeakerID { projected["speakerAttribution"] = try attribution(word.localSpeakerID) }
                var flat = projected
                if !word.hasLocalSpeakerID, utterance.hasLocalSpeakerID {
                    flat["speakerAttribution"] = try attribution(utterance.localSpeakerID)
                }
                words.append(flat)
                return projected
            }
            return parent
        }
        let speakers: [[String: Any]] = try turns.map { turn in
            guard let index = indices[turn.localClusterID] else {
                throw HarcProtobufConversionError.inconsistentField("speakerProjection.unknownTurnCluster")
            }
            return ["speaker": index, "startMs": try milliseconds(turn.startFrame),
                    "endMs": try milliseconds(turn.endFrameExclusive, roundUp: true)]
        }
        var value: [String: Any] = [
            "startedAt": recording.startedAt.timeIntervalSince1970,
            "endedAt": (recording.endedAt ?? recording.startedAt).timeIntervalSince1970,
            "audioPath": recording.wavPath,
            "joinedText": transcript.utterances.map(\.text).joined(separator: "\n\n"),
            "words": words, "speakers": speakers, "chunks": []
        ]
        if let clusterMap {
            value["attributedUtterances"] = utterances
            value["speakerClusterMapSHA256"] = clusterMap.mappingSHA256.base64EncodedString()
        }
        // Local cluster IDs are not authenticated Host person assignments.
        // The exact bundle retains them; this projection does not invent names.
        if transcript.hasOverlapAssessment {
            value["overlapRanges"] = try transcript.overlapAssessment.ranges.map { range in
                ["startMs": try milliseconds(range.startFrame),
                 "endMs": try milliseconds(range.endFrameExclusive, roundUp: true)]
            }
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    /// The exact structured artifact is retained separately; keep its quality
    /// warning visible in the Library's accepted-edge text projection as well.
    static func acceptedTranscriptText(_ transcript: Harc_V1_TranscriptArtifactV1) -> String {
        let text = transcript.utterances.map(\.text).joined(separator: "\n\n")
        guard transcript.hasOverlapAssessment, !transcript.overlapAssessment.ranges.isEmpty else { return text }
        return "Overlapping voices detected. Speaker attribution may be incomplete.\n\n" + text
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
        let selectedDigest: Data?
        let speakerOutcome: HostSpeakerProcessingOutcome?
        if let id = recording.id {
            selectedDigest = try await recordingStore.selectedEdgeArtifactSource(recordingID: id)?.bundleSHA256
            speakerOutcome = selectedDigest == nil ? try await recordingStore.hostSpeakerProcessingOutcome(recordingID: id) : nil
        } else {
            selectedDigest = nil
            speakerOutcome = nil
        }
        return HarcHostProcessingStatusResult(
            canonicalRecordingID: recording.canonicalID,
            originRecordingID: originRecordingID,
            processing: recording.processing,
            projection: recording.projection,
            canonicalAudioSHA256: hash.rawBytes,
            updatedAt: recording.updatedAt,
            selectedEdgeBundleSHA256: selectedDigest,
            hostSpeakerOutcome: speakerOutcome
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
        let selectedDigest: Data?
        let speakerOutcome: HostSpeakerProcessingOutcome?
        if let id = recording.id {
            selectedDigest = try await recordingStore.selectedEdgeArtifactSource(recordingID: id)?.bundleSHA256
            speakerOutcome = selectedDigest == nil ? try await recordingStore.hostSpeakerProcessingOutcome(recordingID: id) : nil
        } else {
            selectedDigest = nil
            speakerOutcome = nil
        }
        return HarcHostProcessingStatusResult(
            canonicalRecordingID: canonicalRecordingID,
            originRecordingID: origin,
            processing: recording.processing,
            projection: recording.projection,
            canonicalAudioSHA256: hash.rawBytes,
            updatedAt: recording.updatedAt,
            selectedEdgeBundleSHA256: selectedDigest,
            hostSpeakerOutcome: speakerOutcome
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
        try DurableFileIO.createDirectory(at: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let name = artifactID.uuidString.lowercased()
        return (
            root.appendingPathComponent("\(name).harcso"),
            root.appendingPathComponent("\(name).harcpb")
        )
    }

    static func persistExact(_ data: Data, at url: URL) throws {
        try persistExact(data, at: url, synchronize: synchronizeExactArtifact)
    }

    static func persistExact(_ data: Data, at url: URL, synchronize: (URL) throws -> Void) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url, options: .mappedIfSafe) == data else {
                throw HarcHostError.provenanceSidecarConflict
            }
            // A previous publication may have reached rename before its barrier
            // failed. Identical bytes do not prove durable publication.
            try synchronize(url)
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
        try synchronize(url)
    }

    private static func synchronizeExactArtifact(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw HarcHostError.stagingIO("Could not open the processing artifact for synchronization.") }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw HarcHostError.stagingIO("Could not synchronize the processing artifact.") }
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
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else {
            throw HarcHostError.stagingIO("Could not flush the processing artifact to storage.")
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
