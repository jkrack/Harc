import CryptoKit
import Foundation
import HarcAudioMobile
import HarcClientStore
import HarcClientTransport
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer
import Observation
import OSLog

struct HarcMobileLocalRecording: Identifiable, Equatable {
    enum TransferState: Equatable {
        case localOnly
        case transferring
        case retryNeeded
        case securityBlocked
        case committed
    }

    static let exportDisclosure =
        "Exporting hands this audio to the destination you choose. "
        + "That destination is outside your adopted Harc Host trust boundary. "
        + "Harc does not treat this export as synchronization."

    let id: UUID
    let originID: OriginRecordingID
    let startedAt: Date
    let duration: TimeInterval
    let masterFileURL: URL
    let transferState: TransferState
    let discontinuities: [CaptureDiscontinuity]

    /// Reads device-owned masters independently of Host adoption, route, or cache.
    /// Transfer state is a badge, never a prerequisite for local playback.
    static func load(from store: HarcTransferStore) throws -> [Self] {
        try store.recordingOutboxes()
            .compactMap { outbox in
                guard outbox.finalizedCapture.masterFileState == .present,
                      FileManager.default.fileExists(
                        atPath: outbox.finalizedCapture.masterFileURL.path
                      ) else {
                    return nil
                }
                let capture = outbox.finalizedCapture.capture
                let transferState: HarcMobileLocalRecording.TransferState =
                    switch outbox.stateMachine.state {
                    case .localOnly:
                        .localOnly
                    case .failedRecoverable:
                        .retryNeeded
                    case .securityBlocked:
                        .securityBlocked
                    case .committed:
                        .committed
                    default:
                        .transferring
                    }
                return HarcMobileLocalRecording(
                    id: capture.originRecordingID.recordingUUID,
                    originID: capture.originRecordingID,
                    startedAt: capture.captureStartedAt,
                    duration: capture.captureEndedAt.timeIntervalSince(
                        capture.captureStartedAt
                    ),
                    masterFileURL:
                        outbox.finalizedCapture.masterFileURL,
                    transferState: transferState,
                    discontinuities: capture.discontinuities
                )
            }
            .sorted { $0.startedAt > $1.startedAt }
    }
}

@MainActor
@Observable
final class HarcMobileTransferCoordinator {
    private static let logger = Logger(
        subsystem: "com.harc.HarcMobile",
        category: "host-transfer"
    )

    enum State: Equatable {
        case idle
        case encoding(recordingUUID: UUID)
        case waitingForPairing(pending: Int)
        case connecting(recordingUUID: UUID)
        case uploading(recordingUUID: UUID)
        case backgroundScheduled(recordingUUID: UUID, taskCount: Int)
        case uploaded(recordingUUID: UUID)
        case codecQualificationRequired(recordingUUID: UUID)
        case retryNeeded(recordingUUID: UUID, message: String)
        case securityBlocked(recordingUUID: UUID, message: String)
    }

    /// Read-only presentation of the unchanged production qualification gate.
    var isCodecQualifiedForTransfers: Bool {
        HarcMobileLosslessReleaseGate.selected == .cafALAC
    }

    private(set) var state: State = .idle
    private(set) var pendingCount = 0
    private(set) var localRecordings: [HarcMobileLocalRecording] = []
    private(set) var localRecordingsError: String?

    private let identity: InstallationSigningIdentity
    private let store: HarcTransferStore
    private let locations: HarcMobileCaptureLocations
    private let routeURL: URL
    private let backgroundUploadClient: HarcBackgroundURLSessionUploadClientV1
    private var queue: [HarcMobileFinalizedMaster] = []
    private var queuedOrigins = Set<OriginRecordingID>()
    private var worker: Task<Void, Never>?
    private var backgroundReconciliationTask: Task<Void, Never>?

    init(
        identity: InstallationSigningIdentity,
        store: HarcTransferStore,
        locations: HarcMobileCaptureLocations,
        routeURL: URL,
        backgroundUploadClient: HarcBackgroundURLSessionUploadClientV1
    ) {
        self.identity = identity
        self.store = store
        self.locations = locations
        self.routeURL = routeURL
        self.backgroundUploadClient = backgroundUploadClient
        refreshLocalRecordings()
    }

    func enqueue(_ master: HarcMobileFinalizedMaster) {
        refreshLocalRecordings()
        guard queuedOrigins.insert(master.originRecordingID).inserted else {
            return
        }
        queue.append(master)
        pendingCount = max(pendingCount, queue.count)
        startWorkerIfNeeded()
    }

    func retryPending() {
        Self.logger.info("Searching the durable outbox for Host transfers to retry")
#if DEBUG
        print("[Harc host-transfer] searching durable outbox")
#endif
        do {
            refreshLocalRecordings()
            let backgroundManagedUploadIDs = try activeBackgroundUploadIDs()
            let hasRelayRoute = (try? HarcMobileHostRouteStore.load(
                from: routeURL
            ).relay) != nil
            let pending = try store.recordingOutboxes().filter {
                $0.stateMachine.state != .committed
                    && $0.stateMachine.state != .securityBlocked
                    && $0.integrityBlock == nil
                    && $0.finalizedCapture.masterFileState == .present
                    && !Self.shouldDeferToBackgroundUpload(
                        uploadID: $0.uploadID,
                        backgroundManagedUploadIDs:
                            backgroundManagedUploadIDs,
                        hasRelayRoute: hasRelayRoute
                    )
            }
            let eligible = try pending.filter {
                try HarcMobileUploadPreparation.canAttempt(
                    origin: $0.finalizedCapture.capture.originRecordingID, store: store
                )
            }
            pendingCount = eligible.count
            Self.logger.info("Found \(eligible.count, privacy: .public) Host transfer(s) eligible for retry")
#if DEBUG
            print("[Harc host-transfer] eligible retries: \(eligible.count)")
#endif
            for outbox in eligible {
                let master = try Self.master(from: outbox.finalizedCapture)
                guard queuedOrigins.insert(master.originRecordingID).inserted
                else { continue }
                queue.append(master)
            }
            startWorkerIfNeeded()
        } catch {
            Self.logger.error("Could not prepare Host transfer retries: \(String(reflecting: error), privacy: .public)")
#if DEBUG
            print("[Harc host-transfer] retry preparation failed: \(String(reflecting: error))")
#endif
            state = .retryNeeded(
                recordingUUID: UUID(),
                message: error.localizedDescription
            )
        }
    }

    func retry(recordingUUID: UUID) {
        let origin = OriginRecordingID(
            deviceID: identity.deviceID,
            recordingUUID: recordingUUID
        )
        do {
            let resumedBackground = try store
                .resumeSecurityBlockedBackgroundUpload(for: origin)
            if !resumedBackground,
               let outbox = try store.recordingOutbox(for: origin),
               outbox.stateMachine.state == .securityBlocked {
                _ = try store.updateRecordingOutbox(for: origin) { machine in
                    try machine.resumeAfterUserSecurityAction()
                }
            }
            retryPending()
        } catch {
            state = .securityBlocked(
                recordingUUID: recordingUUID,
                message: Self.diagnosticMessage(error)
            )
            refreshLocalRecordings()
        }
    }

    func refreshLocalRecordings() {
        do {
            localRecordings = try HarcMobileLocalRecording.load(from: store)
            localRecordingsError = nil
        } catch {
            localRecordingsError = error.localizedDescription
        }
    }

    func reconcileBackgroundUploads() {
        guard backgroundReconciliationTask == nil else { return }
        backgroundReconciliationTask = Task { [weak self] in
            guard let self else { return }
            defer { backgroundReconciliationTask = nil }
            do {
                let result = try await backgroundUploadClient
                    .reconcileAfterRelaunch()
#if DEBUG
                let reconciliation = result.storeReconciliation
                print(
                    "[Harc host-transfer] background reconciliation "
                    + "matched=\(reconciliation.matchedTasks.count) "
                    + "rescheduled=\(result.newlyScheduledTasks.count) "
                    + "refresh=\(result.batchesRequiringCapabilityRefresh.count)"
                )
                for summary in await backgroundUploadClient
                    .debugTaskSummary() {
                    print("[Harc host-transfer] \(summary)")
                }
#endif
                retryPending()
            } catch {
                state = .retryNeeded(
                    recordingUUID: UUID(),
                    message: Self.diagnosticMessage(error)
                )
            }
        }
    }

    private func activeBackgroundUploadIDs() throws -> Set<UploadID> {
        var uploadIDs = Set<UploadID>()
        for mapping in try store.taskMappings() {
            guard mapping.state == .persistedBeforeResume
                    || mapping.state == .observedBySystem,
                  let batch = try store.backgroundBatch(id: mapping.batchID)
            else { continue }
            uploadIDs.insert(batch.descriptor.uploadID)
        }
        return uploadIDs
    }

    /// A background URLSession capability is intentionally minted for the
    /// Host's LAN-only `.local` endpoint. When the adoption also has an
    /// encrypted relay route, keep the recording eligible for a foreground
    /// retry: the connector may discover that only the relay is reachable.
    /// `scheduleInBackground` remains idempotent when the direct route wins.
    static func shouldDeferToBackgroundUpload(
        uploadID: UploadID?,
        backgroundManagedUploadIDs: Set<UploadID>,
        hasRelayRoute: Bool
    ) -> Bool {
        guard !hasRelayRoute, let uploadID else { return false }
        return backgroundManagedUploadIDs.contains(uploadID)
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        defer { worker = nil }
        do {
            try await HarcMobileTransferWorkQueue.drain(
                identity: { $0.originRecordingID },
                next: { self.queue.isEmpty ? nil : self.queue.removeFirst() },
                shouldAttempt: {
                    try HarcMobileUploadPreparation.canAttempt(origin: $0.originRecordingID, store: self.store)
                },
                process: { master in
                    let recordingID = master.originRecordingID.recordingUUID.uuidString
                    Self.logger.info("Starting Host transfer retry for recording \(recordingID, privacy: .public)")
#if DEBUG
                    print("[Harc host-transfer] starting \(recordingID)")
#endif
                    let outcome = try await transfer(master)
                    queuedOrigins.remove(master.originRecordingID)
                    switch outcome {
                    case .committed:
                        pendingCount = max(0, pendingCount - 1)
                        state = .uploaded(
                            recordingUUID: master.originRecordingID.recordingUUID
                        )
                    case .backgroundScheduled(let taskCount):
                        state = .backgroundScheduled(
                            recordingUUID: master.originRecordingID.recordingUUID,
                            taskCount: taskCount
                        )
                    }
                    refreshLocalRecordings()
                },
                skipped: { master in
                    self.queuedOrigins.remove(master.originRecordingID)
                    self.pendingCount = max(self.queue.count, max(0, self.pendingCount - 1))
                    self.refreshLocalRecordings()
                },
                failed: { master, error in
                    try self.handleTransferFailure(error, master: master)
                }
            )
        } catch {
            // Global pairing/codec stops already rendered their visible state.
            // Leave remaining queue entries for a later explicit retry/wake.
        }
    }

    private func handleTransferFailure(
        _ error: any Error, master: HarcMobileFinalizedMaster
    ) throws {
        Self.logger.error("Host transfer failed: \(String(reflecting: error), privacy: .public)")
        queuedOrigins.remove(master.originRecordingID)
        try HarcMobileTransferFailureAdapter.handle(
            error, origin: master.originRecordingID, store: store,
            report: { presentation in
                switch presentation {
                case .cancelled:
                    break
                case .waitingForPairing:
                    pendingCount = max(pendingCount, queue.count + 1)
                    state = .waitingForPairing(pending: pendingCount)
                case .codecQualificationRequired:
                    pendingCount = max(pendingCount, queue.count + 1)
                    state = .codecQualificationRequired(recordingUUID: master.originRecordingID.recordingUUID)
                case .securityBlocked(let message):
                    pendingCount = max(pendingCount, queue.count + 1)
                    state = .securityBlocked(recordingUUID: master.originRecordingID.recordingUUID, message: message)
                case .retryNeeded(let message):
                    state = .retryNeeded(recordingUUID: master.originRecordingID.recordingUUID, message: message)
                }
                refreshLocalRecordings()
            },
            persistenceFailure: {
                Self.logger.error("Could not persist pairing-repair security stop: \(String(reflecting: $0), privacy: .public)")
            }
        )
    }

    private enum TransferOutcome {
        case committed
        case backgroundScheduled(taskCount: Int)
    }

    private func transfer(
        _ master: HarcMobileFinalizedMaster
    ) async throws -> TransferOutcome {
        state = .encoding(
            recordingUUID: master.originRecordingID.recordingUUID
        )
        guard HarcMobileLosslessReleaseGate.selected == .cafALAC else {
            throw HarcMobileTransferError.codecNotQualified
        }
        let locations = locations
        let artifacts = try await HarcMobileUploadPreparation.artifacts(
            origin: master.originRecordingID, store: store,
            encode: {
                try await Task.detached(priority: .utility) {
                    try HarcMobileALACChunkEncoder().encode(master, locations: locations)
                }.value
            }
        ) ?? []
        Self.logger.info("Host transfer artifacts are ready; opening the adopted Host session")
#if DEBUG
        print("[Harc host-transfer] artifacts ready; opening Host session")
#endif

        state = .connecting(
            recordingUUID: master.originRecordingID.recordingUUID
        )
        let opened: HarcMobileOpenedHostConnection
        do {
            opened = try await HarcMobileHostSessionConnector.open(
                identity: identity,
                store: store,
                routeURL: routeURL
            )
            Self.logger.info("Opened the adopted Host session")
#if DEBUG
            print("[Harc host-transfer] Host session opened")
#endif
        } catch HarcMobileHostSessionConnectorError.notPaired {
            throw HarcMobileTransferError.notPaired
        }
        let connection = opened.connection
        do {
            let plan = try HarcMobileUploadPreparation.plan(
                origin: master.originRecordingID, store: store,
                currentTrustTuple: AdoptedTrustTuple(
                    libraryID: opened.adoption.hostTrust.libraryID,
                    hostAuthorityID: opened.adoption.hostTrust.hostAuthorityID
                ),
                freshProfile: { try Self.frozenProfile(negotiated: opened.negotiated) },
                freshChunks: {
                    try artifacts.map { artifact in
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
                }
            )
            guard plan.frozenProfile.encoding == .cafALAC,
                  plan.frozenProfile.purpose == .production else {
                throw HarcForegroundRecordingOutboxError.securityBindingMismatch(field: "productionUploadProfile")
            }
            state = .uploading(
                recordingUUID: master.originRecordingID.recordingUUID
            )
            let uploader = HarcForegroundRecordingOutboxCoordinator(
                store: store,
                transport: connection
            )
            if opened.path == .encryptedRelay {
                Self.logger.info(
                    "Uploading through the end-to-end encrypted relay session"
                )
                _ = try await uploader.drive(
                    plan,
                    openedSession: opened.session,
                    deviceSigner: identity
                )
                try await connection.shutdownGracefully()
                return .committed
            }
            let result = try await uploader.scheduleInBackground(
                plan,
                openedSession: opened.session,
                deviceSigner: identity,
                batchPreparer: HarcMobileBackgroundBatchPreparer(
                    locations: locations
                ),
                scheduler: backgroundUploadClient
            )
            try await connection.shutdownGracefully()
            switch result {
            case .committed:
                return .committed
            case .scheduled(let identities):
                return .backgroundScheduled(taskCount: identities.count)
            }
        } catch {
            await connection.shutdownImmediately()
            throw error
        }
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
        var input = Data("harc-mobile-chunk-id-v1".utf8)
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

    private static func diagnosticMessage(_ error: any Error) -> String {
        HarcMobileTransferFailureAdapter.diagnosticMessage(error)
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

/// This compile-time gate is deliberately closed until the physical-iPhone
/// matrix in the implementation spec freezes a release codec. Enabling it is
/// a reviewed release change backed by the signed qualification report.
private enum HarcMobileLosslessReleaseGate {
    #if HARC_MOBILE_QUALIFIED_CAF_ALAC
    static let selected: LosslessEncodingConfiguration? = .cafALAC
    #else
    static let selected: LosslessEncodingConfiguration? = nil
    #endif
}
