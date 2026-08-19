import Combine
import CryptoKit
import Foundation
import HarcAudioMobile
import HarcClientStore
import HarcClientTransport
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer

@MainActor
final class HarcDesktopClientTransferCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case encoding(UUID)
        case waitingForPairing(pending: Int)
        case connecting(UUID)
        case uploading(UUID)
        case uploaded(UUID)
        case edgeArtifactDeferred(UUID, String)
        case retryNeeded(UUID, String)
        case securityBlocked(UUID, String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var pendingCount = 0

    private let identity: InstallationSigningIdentity
    private let store: HarcTransferStore
    private let locations: HarcMobileCaptureLocations
    private let clientRoot: URL
    private let routeURL: URL
    private var queue: [HarcMobileFinalizedMaster] = []
    private var queuedOrigins = Set<OriginRecordingID>()
    /// Set by Client archive reconciliation. These origins remain fail-closed
    /// until a later successful inventory proves their local facts again.
    private var recoveryBlockedOrigins = Set<OriginRecordingID>()
    private var worker: Task<Void, Never>?

    init(
        identity: InstallationSigningIdentity,
        store: HarcTransferStore,
        clientRoot: URL,
        routeURL: URL
    ) throws {
        self.identity = identity
        self.store = store
        self.clientRoot = clientRoot
        locations = try HarcMobileCaptureLocations(
            applicationSupportRoot: clientRoot
        )
        self.routeURL = routeURL
    }

    var statusMessage: String {
        switch state {
        case .idle:
            pendingCount == 0
                ? "Client storage ready"
                : "\(pendingCount) recording(s) waiting for Host"
        case .encoding:
            "Compressing a recording for Host"
        case .waitingForPairing(let pending):
            "\(pending) recording(s) waiting for Host pairing"
        case .connecting:
            "Connecting securely to Host"
        case .uploading:
            "Uploading a recording to Host"
        case .uploaded:
            pendingCount == 0
                ? "All Client recordings are on Host"
                : "\(pendingCount) recording(s) still waiting for Host"
        case .edgeArtifactDeferred(_, let message):
            "Audio is safe on Host; local metadata handoff will retry: \(message)"
        case .retryNeeded(_, let message):
            "Host transfer needs retry: \(message)"
        case .securityBlocked(_, let message):
            "Host transfer blocked for security: \(message)"
        }
    }

    func retryPending() {
        do {
            let pending = try store.recordingOutboxes().filter { outbox in
                guard !recoveryBlockedOrigins.contains(
                    outbox.finalizedCapture.capture.originRecordingID
                ) else { return false }
                let transferable = outbox.stateMachine.state != .securityBlocked
                    && outbox.integrityBlock == nil
                    && outbox.finalizedCapture.masterFileState == .present
                return transferable && (
                    outbox.stateMachine.state != .committed
                        || Self.needsProcessingArtifact(
                            origin: outbox.finalizedCapture.capture
                                .originRecordingID,
                            clientRoot: clientRoot
                        )
                        || Self.needsSpeakerObservations(
                            origin: outbox.finalizedCapture.capture
                                .originRecordingID,
                            clientRoot: clientRoot
                        )
                )
            }
            pendingCount = pending.count
            for outbox in pending {
                let master = try Self.master(from: outbox.finalizedCapture)
                guard queuedOrigins.insert(master.originRecordingID).inserted
                else { continue }
                queue.append(master)
            }
            if pending.isEmpty { state = .idle }
            startWorkerIfNeeded()
        } catch {
            state = .retryNeeded(UUID(), error.localizedDescription)
        }
    }

    func setRecoveryBlockedOrigins(_ origins: Set<OriginRecordingID>) {
        recoveryBlockedOrigins = origins
        queue.removeAll { origins.contains($0.originRecordingID) }
        queuedOrigins.subtract(origins)
    }

    func shutdown() {
        worker?.cancel()
        worker = nil
        queue.removeAll()
        queuedOrigins.removeAll()
        state = .idle
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        defer { worker = nil }
        while !queue.isEmpty {
            guard !Task.isCancelled else { return }
            let master = queue.removeFirst()
            do {
                let artifactFailure = try await transfer(master)
                queuedOrigins.remove(master.originRecordingID)
                pendingCount = max(0, pendingCount - 1)
                if let artifactFailure {
                    state = .edgeArtifactDeferred(
                        master.originRecordingID.recordingUUID,
                        artifactFailure
                    )
                } else {
                    state = .uploaded(
                        master.originRecordingID.recordingUUID
                    )
                }
            } catch HarcDesktopClientTransferError.notPaired {
                queuedOrigins.remove(master.originRecordingID)
                pendingCount = max(pendingCount, queue.count + 1)
                state = .waitingForPairing(pending: pendingCount)
                return
            } catch is CancellationError {
                queuedOrigins.remove(master.originRecordingID)
                return
            } catch {
                queuedOrigins.remove(master.originRecordingID)
                let outbox = try? store.recordingOutbox(
                    for: master.originRecordingID
                )
                if outbox?.stateMachine.state == .securityBlocked {
                    state = .securityBlocked(
                        master.originRecordingID.recordingUUID,
                        error.localizedDescription
                    )
                } else {
                    state = .retryNeeded(
                        master.originRecordingID.recordingUUID,
                        error.localizedDescription
                    )
                }
                return
            }
        }
    }

    private func transfer(
        _ master: HarcMobileFinalizedMaster
    ) async throws -> String? {
        let alreadyCommitted = try store.recordingOutbox(
            for: master.originRecordingID
        )?.stateMachine.state == .committed
        let artifacts: [HarcMobileEncodedChunkArtifact]
        if alreadyCommitted {
            // Artifact-only retries must not re-encode or replay audio that the
            // Host has already committed and acknowledged.
            artifacts = []
        } else {
            state = .encoding(master.originRecordingID.recordingUUID)
            let locations = locations
            artifacts = try await Task.detached(priority: .utility) {
                try HarcMobileALACChunkEncoder().encode(
                    master,
                    locations: locations
                )
            }.value
        }

        state = .connecting(master.originRecordingID.recordingUUID)
        let opened: HarcDesktopOpenedHostConnection
        do {
            opened = try await HarcDesktopHostSessionConnector.open(
                identity: identity,
                store: store,
                routeURL: routeURL
            )
        } catch HarcDesktopHostConnectionError.notPaired {
            throw HarcDesktopClientTransferError.notPaired
        }
        let connection = opened.connection
        do {
            if alreadyCommitted {
                guard let receipt = try store.verifiedRecordingReceipt(
                    for: master.originRecordingID
                ) else {
                    throw HarcDesktopClientTransferError.missingVerifiedReceipt
                }
                let artifactFailure = try await submitProcessingArtifactIfPresent(
                    origin: master.originRecordingID,
                    opened: opened
                )
                let speakerFailure = try await submitSpeakerObservationsIfPresent(
                    origin: master.originRecordingID,
                    canonicalID: receipt.canonicalRecordingID,
                    opened: opened
                )
                try await connection.shutdownGracefully()
                return Self.combinedDeferredMessage(
                    artifactFailure,
                    speakerFailure
                )
            }
            let profile = try Self.frozenProfile(
                negotiated: opened.negotiated
            )
            let outbox = try store.recordingOutbox(
                for: master.originRecordingID
            )
            let existingIntent = try store.uploadBeginIntent(
                for: master.originRecordingID
            )
            let uploadID = existingIntent?.intent.uploadID
                ?? outbox?.uploadID
                ?? .random()
            let chunks = try artifacts.map { artifact in
                let descriptor = try LogicalChunkDescriptor(
                    originRecordingID: master.originRecordingID,
                    chunkID: Self.chunkID(
                        origin: master.originRecordingID,
                        index: artifact.chunkIndex
                    ),
                    chunkIndex: artifact.chunkIndex,
                    canonicalStartFrame: artifact.canonicalStartFrame,
                    canonicalFrameCount: artifact.canonicalFrameCount,
                    encoding: .cafALAC,
                    encodedByteLength: artifact.encodedByteLength,
                    encodedSHA256: try EncodedChunkSHA256(
                        artifact.encodedSHA256
                    ),
                    canonicalDecodedByteLength:
                        artifact.canonicalDecodedByteLength,
                    canonicalDecodedSHA256: try CanonicalPCMHash(
                        artifact.canonicalDecodedSHA256
                    )
                )
                return try HarcForegroundEncodedChunk(
                    descriptor: descriptor,
                    encodedFileURL: artifact.encodedFileURL
                )
            }
            let plan = try HarcForegroundRecordingUploadPlan(
                trustTuple: AdoptedTrustTuple(
                    libraryID: opened.adoption.hostTrust.libraryID,
                    hostAuthorityID:
                        opened.adoption.hostTrust.hostAuthorityID
                ),
                uploadID: uploadID,
                originRecordingID: master.originRecordingID,
                frozenProfile: profile,
                chunks: chunks
            )
            state = .uploading(master.originRecordingID.recordingUUID)
            let uploader = HarcForegroundRecordingOutboxCoordinator(
                store: store,
                transport: connection
            )
            let receipt = try await uploader.drive(
                plan,
                openedSession: opened.session,
                deviceSigner: identity
            )
            let artifactFailure = try await submitProcessingArtifactIfPresent(
                origin: master.originRecordingID,
                opened: opened
            )
            let speakerFailure = try await submitSpeakerObservationsIfPresent(
                origin: master.originRecordingID,
                canonicalID: receipt.canonicalRecordingID,
                opened: opened
            )
            try await connection.shutdownGracefully()
            return Self.combinedDeferredMessage(
                artifactFailure,
                speakerFailure
            )
        } catch {
            await connection.shutdownImmediately()
            throw error
        }
    }

    private func submitSpeakerObservationsIfPresent(
        origin: OriginRecordingID,
        canonicalID: CanonicalRecordingID,
        opened: HarcDesktopOpenedHostConnection
    ) async throws -> String? {
        do {
            let sidecarURL = Self.captureSidecarURL(
                origin: origin,
                clientRoot: clientRoot
            )
            let sidecar = try JSONDecoder().decode(
                HarcDesktopClientCaptureSidecar.self,
                from: Data(contentsOf: sidecarURL, options: .mappedIfSafe)
            )
            let embeddings = sidecar.speakerEmbeddings ?? []
            guard !embeddings.isEmpty else { return nil }
            guard opened.adoption.grant.scopes.contains(
                .speakerObservationWrite
            ) else {
                throw HarcDesktopClientTransferError.speakerScopeNotGranted
            }

            let authorization = try HarcLibraryAuthorization(
                openedSession: opened.session
            )
            var pack: SpeakerRecognitionPack?
            if opened.adoption.grant.scopes.contains(.speakerIdentityRead) {
                var packRequest = Harc_V1_GetSpeakerRecognitionPackRequestV1()
                packRequest.protocol = HarcProtocolVersion.v1.protobufV1()
                let response = try await opened.connection
                    .getSpeakerRecognitionPack(
                        packRequest,
                        authorization: authorization
                    )
                try Self.validateLibraryProtocol(
                    response.hasProtocol,
                    response.protocol
                )
                guard response.unchanged != response.hasPack else {
                    throw HarcDesktopClientTransferError
                        .malformedSpeakerResponse
                }
                if response.hasPack { pack = try response.pack.domainValue() }
            }

            for row in embeddings {
                guard row.speakerIndex >= 0,
                      row.totalMs > 0,
                      row.segmentCount > 0 else { continue }
                let quantized = try QuantizedSpeakerEmbedding.quantizing(
                    row.vector
                )
                let match = pack.flatMap {
                    SpeakerRecognitionMatcher.bestMatch(
                        embedding: quantized,
                        modelID: "wespeaker_v2",
                        pack: $0
                    )
                }
                let observation = try SpeakerEmbeddingObservation(
                    operationID: Self.observationOperationID(
                        origin: origin,
                        speakerIndex: row.speakerIndex
                    ),
                    canonicalRecordingID: canonicalID,
                    speakerIndex: UInt32(row.speakerIndex),
                    embedding: quantized,
                    modelID: "wespeaker_v2",
                    speechDurationMs: UInt64(row.totalMs),
                    segmentCount: UInt32(row.segmentCount),
                    sourcePackRevision: match?.packRevision ?? pack?.revision,
                    proposedPersonID: match?.personID,
                    proposedScore: match?.score
                )
                var request = Harc_V1_SubmitSpeakerObservationRequestV1()
                request.protocol = HarcProtocolVersion.v1.protobufV1()
                request.observation = Harc_V1_SpeakerEmbeddingObservationV1(
                    observation
                )
                let response = try await opened.connection
                    .submitSpeakerObservation(
                        request,
                        authorization: authorization
                    )
                try Self.validateLibraryProtocol(
                    response.hasProtocol,
                    response.protocol
                )
                guard response.hasDecision,
                      try response.decision.domainValue().operationID
                        == observation.operationID else {
                    throw HarcDesktopClientTransferError
                        .malformedSpeakerResponse
                }
            }

            let marker = HarcDesktopSpeakerObservationMarker(
                canonicalRecordingID: canonicalID,
                acceptedAt: Date()
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try HarcDesktopClientFiles.writeProtectedData(
                encoder.encode(marker),
                to: Self.speakerObservationMarkerURL(
                    origin: origin,
                    clientRoot: clientRoot
                )
            )
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return error.localizedDescription
        }
    }

    private func submitProcessingArtifactIfPresent(
        origin: OriginRecordingID,
        opened: HarcDesktopOpenedHostConnection
    ) async throws -> String? {
        do {
            guard let submission = try durableProcessingSubmission(
                origin: origin,
                adoption: opened.adoption
            ) else { return nil }
            let authorization = try HarcProcessingAuthorization(
                openedSession: opened.session
            )
            let requests = HarcDesktopProcessingArtifactBuilder.requests(
                for: submission
            )
            let response = try await opened.connection.submitOwnArtifact(
                authorization: authorization,
                requestProducer: { writer in
                    for request in requests {
                        try Task.checkCancellation()
                        try await writer.write(request)
                    }
                }
            )
            guard response.hasProtocol,
                  response.protocol.major == 1,
                  response.protocol.minor
                    == opened.negotiated.protocolVersion.minor,
                  response.disposition
                    != Harc_V1_ProcessingSubmissionDispositionV1
                        .processingSubmissionDispositionUnspecified else {
                throw HarcDesktopClientTransferError.malformedProcessingResponse
            }
            let marker = HarcDesktopProcessingMarker(
                exactSignedMetadataSHA256: Data(
                    SHA256.hash(data: submission.exactSignedMetadata)
                ),
                disposition: response.disposition.rawValue,
                acceptedAt: Date()
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try HarcDesktopClientFiles.writeProtectedData(
                encoder.encode(marker),
                to: Self.processingMarkerURL(
                    origin: origin,
                    clientRoot: clientRoot
                )
            )
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return error.localizedDescription
        }
    }

    private func durableProcessingSubmission(
        origin: OriginRecordingID,
        adoption: ValidatedClientAdoptionEvidence
    ) throws -> HarcDesktopProcessingSubmission? {
        let url = Self.processingSubmissionURL(
            origin: origin,
            grantID: adoption.grant.grantID,
            grantEpoch: adoption.grant.registryEpoch,
            clientRoot: clientRoot
        )
        if FileManager.default.fileExists(atPath: url.path) {
            let persisted = try JSONDecoder().decode(
                HarcDesktopProcessingSubmission.self,
                from: Data(contentsOf: url, options: .mappedIfSafe)
            )
            guard !persisted.exactSignedMetadata.isEmpty,
                  persisted.exactSignedMetadata.count
                    <= HarcProtocolLimits.signedObjectBytes,
                  !persisted.exactBundle.isEmpty,
                  persisted.exactBundle.count
                    <= HarcProcessingBundleV1.maximumExactBytes else {
                throw HarcDesktopClientTransferError
                    .invalidDurableProcessingSubmission
            }
            return persisted
        }
        guard let submission = try HarcDesktopProcessingArtifactBuilder
            .makeSubmission(
                origin: origin,
                clientRoot: clientRoot,
                adoption: adoption,
                identity: identity
            ) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try HarcDesktopClientFiles.writeProtectedData(
            encoder.encode(submission),
            to: url
        )
        return submission
    }

    private static func needsProcessingArtifact(
        origin: OriginRecordingID,
        clientRoot: URL
    ) -> Bool {
        let marker = processingMarkerURL(origin: origin, clientRoot: clientRoot)
        guard !FileManager.default.fileExists(atPath: marker.path) else {
            return false
        }
        let sidecar = clientRoot
            .appendingPathComponent("Captures", isDirectory: true)
            .appendingPathComponent(
                "\(origin.recordingUUID.uuidString.lowercased()).capture.json"
            )
        guard let data = try? Data(contentsOf: sidecar, options: .mappedIfSafe),
              let decoded = try? JSONDecoder().decode(
                HarcDesktopClientCaptureSidecar.self,
                from: data
              ) else { return false }
        return decoded.transcript != nil
    }

    private static func needsSpeakerObservations(
        origin: OriginRecordingID,
        clientRoot: URL
    ) -> Bool {
        guard !FileManager.default.fileExists(
            atPath: speakerObservationMarkerURL(
                origin: origin,
                clientRoot: clientRoot
            ).path
        ) else { return false }
        guard let data = try? Data(
            contentsOf: captureSidecarURL(
                origin: origin,
                clientRoot: clientRoot
            ),
            options: .mappedIfSafe
        ), let sidecar = try? JSONDecoder().decode(
            HarcDesktopClientCaptureSidecar.self,
            from: data
        ) else { return false }
        return !(sidecar.speakerEmbeddings ?? []).isEmpty
    }

    private static func captureSidecarURL(
        origin: OriginRecordingID,
        clientRoot: URL
    ) -> URL {
        clientRoot
            .appendingPathComponent("Captures", isDirectory: true)
            .appendingPathComponent(
                "\(origin.recordingUUID.uuidString.lowercased()).capture.json"
            )
    }

    private static func speakerObservationMarkerURL(
        origin: OriginRecordingID,
        clientRoot: URL
    ) -> URL {
        clientRoot
            .appendingPathComponent("Captures", isDirectory: true)
            .appendingPathComponent(
                "\(origin.recordingUUID.uuidString.lowercased()).speakers-accepted.json"
            )
    }

    private static func processingMarkerURL(
        origin: OriginRecordingID,
        clientRoot: URL
    ) -> URL {
        clientRoot
            .appendingPathComponent("Captures", isDirectory: true)
            .appendingPathComponent(
                "\(origin.recordingUUID.uuidString.lowercased()).edge-accepted.json"
            )
    }

    private static func processingSubmissionURL(
        origin: OriginRecordingID,
        grantID: GrantID,
        grantEpoch: UInt64,
        clientRoot: URL
    ) -> URL {
        clientRoot
            .appendingPathComponent("Captures", isDirectory: true)
            .appendingPathComponent(
                "\(origin.recordingUUID.uuidString.lowercased()).edge-submission."
                    + "\(grantID.description).\(grantEpoch).json"
            )
    }

    private static func frozenProfile(
        negotiated: HarcValidatedNegotiatedCapabilitiesV1
    ) throws -> FrozenUploadProfile {
        let protocolVersion = try TransferProtocolVersion(
            minor: negotiated.protocolVersion.minor
        )
        let capabilities = try negotiated.selectedFeatureIDs
            .map(TransferCapabilityID.init)
            .sorted()
        let negotiatedDigest = try NegotiatedCapabilitiesSHA256(
            negotiated.exactSHA256
        )
        let provisional = try FrozenUploadProfile(
            protocolVersion: protocolVersion,
            encoding: negotiated.encoding,
            requiredCapabilities: capabilities,
            negotiatedCapabilitiesSHA256: negotiatedDigest,
            profileSHA256: try UploadProfileSHA256(
                Data(repeating: 0, count: 32)
            ),
            purpose: .production
        )
        let exact = try HarcExactProtobufPayload(
            serializingOnce: Harc_V1_UploadProfileV1(provisional)
        )
        return try FrozenUploadProfile(
            protocolVersion: protocolVersion,
            encoding: negotiated.encoding,
            requiredCapabilities: capabilities,
            negotiatedCapabilitiesSHA256: negotiatedDigest,
            profileSHA256: try UploadProfileSHA256(
                HarcSignedEnvelopeV1.payloadDigest(exact.exactBytes)
            ),
            purpose: .production
        )
    }

    private static func chunkID(
        origin: OriginRecordingID,
        index: UInt32
    ) -> ChunkID {
        var input = Data("harc-desktop-chunk-id-v1".utf8)
        input.append(origin.deviceID.rawBytes)
        input.append(Data(origin.recordingUUID.uuidString.lowercased().utf8))
        var bigEndianIndex = index.bigEndian
        withUnsafeBytes(of: &bigEndianIndex) { input.append(contentsOf: $0) }
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = bytes.withUnsafeBufferPointer { buffer in
            UUID(uuidString: NSUUID(uuidBytes: buffer.baseAddress!).uuidString)!
        }
        return ChunkID(uuid)
    }

    private static func observationOperationID(
        origin: OriginRecordingID,
        speakerIndex: Int
    ) -> OperationID {
        var input = Data("harc-desktop-speaker-observation-v1".utf8)
        input.append(origin.deviceID.rawBytes)
        input.append(Data(origin.recordingUUID.uuidString.lowercased().utf8))
        var index = Int64(speakerIndex).bigEndian
        withUnsafeBytes(of: &index) { input.append(contentsOf: $0) }
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = bytes.withUnsafeBufferPointer { buffer in
            UUID(uuidString: NSUUID(uuidBytes: buffer.baseAddress!).uuidString)!
        }
        return OperationID(uuid)
    }

    private static func validateLibraryProtocol(
        _ hasProtocol: Bool,
        _ value: Harc_V1_ProtocolVersionV1
    ) throws {
        guard hasProtocol,
              value.major == HarcProtocolVersion.v1.major,
              value.minor == HarcProtocolVersion.v1.minor else {
            throw HarcDesktopClientTransferError.malformedSpeakerResponse
        }
    }

    private static func combinedDeferredMessage(
        _ first: String?,
        _ second: String?
    ) -> String? {
        [first, second].compactMap { $0 }.nilIfEmpty?
            .joined(separator: " ")
    }

    private static func master(
        from stored: StoredFinalizedCapture
    ) throws -> HarcMobileFinalizedMaster {
        let capture = stored.capture
        let reason: HarcMobileCaptureFinalizationReason =
            switch capture.finalizationReason {
            case .userStopped: .userStopped
            case .systemEnded: .systemEnded
            case .recoveredDurablePrefix: .recoveredDurablePrefix
            case .storageExhausted: .storageExhausted
            case .writerFailure: .writerFailure
            }
        return try HarcMobileFinalizedMaster(
            producingDeviceID: capture.producingDeviceID,
            originRecordingID: capture.originRecordingID,
            masterFileURL: stored.masterFileURL,
            captureStartedAt: capture.captureStartedAt,
            captureEndedAt: capture.captureEndedAt,
            captureStartedMonotonicNanoseconds:
                capture.captureStartedMonotonicNanoseconds,
            captureEndedMonotonicNanoseconds:
                capture.captureEndedMonotonicNanoseconds,
            finalizationReason: reason,
            totalCanonicalFrames: capture.totalCanonicalFrames,
            canonicalPCMSHA256: capture.canonicalPCMSHA256,
            discontinuities: capture.discontinuities
        )
    }
}

private enum HarcDesktopClientTransferError: LocalizedError {
    case notPaired
    case malformedProcessingResponse
    case invalidDurableProcessingSubmission
    case missingVerifiedReceipt
    case speakerScopeNotGranted
    case malformedSpeakerResponse

    var errorDescription: String? {
        switch self {
        case .notPaired:
            "The paired Harc Host is unavailable."
        case .malformedProcessingResponse:
            "The Host returned an invalid processing status."
        case .invalidDurableProcessingSubmission:
            "The saved processing submission is invalid."
        case .missingVerifiedReceipt:
            "The Host did not return a verified recording receipt."
        case .speakerScopeNotGranted:
            "This pairing predates shared speaker identity. Re-pair this Mac with the Host."
        case .malformedSpeakerResponse:
            "The Host returned invalid speaker identity data."
        }
    }
}

private struct HarcDesktopProcessingMarker: Codable, Sendable {
    let exactSignedMetadataSHA256: Data
    let disposition: Int
    let acceptedAt: Date
}

private struct HarcDesktopSpeakerObservationMarker: Codable, Sendable {
    let canonicalRecordingID: CanonicalRecordingID
    let acceptedAt: Date
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
