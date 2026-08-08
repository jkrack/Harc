import CryptoKit
import Foundation
import HarcClientStore
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer

public struct HarcForegroundEncodedChunk: Equatable, Sendable {
    public let descriptor: LogicalChunkDescriptor
    public let encodedFileURL: URL

    public init(
        descriptor: LogicalChunkDescriptor,
        encodedFileURL: URL
    ) throws {
        guard encodedFileURL.isFileURL else {
            throw HarcForegroundRecordingOutboxError.invalidPlan(
                field: "encodedFileURL"
            )
        }
        self.descriptor = descriptor
        self.encodedFileURL = encodedFileURL.standardizedFileURL
    }
}

/// Immutable input for driving one already-finalized local capture to its
/// adopted host. The coordinator never removes either the master or encoded
/// chunk files; only `persistVerifiedRecordingReceipt` can open the separate
/// cleanup gate after full receipt validation.
public struct HarcForegroundRecordingUploadPlan: Equatable, Sendable {
    public let trustTuple: AdoptedTrustTuple
    public let uploadID: UploadID
    public let originRecordingID: OriginRecordingID
    public let frozenProfile: FrozenUploadProfile
    public let chunks: [HarcForegroundEncodedChunk]

    public init(
        trustTuple: AdoptedTrustTuple,
        uploadID: UploadID,
        originRecordingID: OriginRecordingID,
        frozenProfile: FrozenUploadProfile,
        chunks: [HarcForegroundEncodedChunk]
    ) throws {
        guard !chunks.isEmpty,
              chunks.count <= TransferLimits.declaredChunksPerUpload else {
            throw HarcForegroundRecordingOutboxError.invalidPlan(
                field: "chunks"
            )
        }
        let descriptors = chunks.map(\.descriptor)
        guard descriptors.allSatisfy({
            $0.originRecordingID == originRecordingID
        }), descriptors.map(\.chunkIndex) == Array(0 ..< UInt32(descriptors.count)) else {
            throw HarcForegroundRecordingOutboxError.invalidPlan(
                field: "chunkOrder"
            )
        }
        self.trustTuple = trustTuple
        self.uploadID = uploadID
        self.originRecordingID = originRecordingID
        self.frozenProfile = frozenProfile
        self.chunks = chunks
    }
}

/// One immutable HARCAB1 file prepared by the application composition layer
/// after the host has assigned the upload generation.
public struct HarcPreparedBackgroundAudioBatchV1: Sendable {
    public let descriptor: ImmutableAudioBatchDescriptor
    public let bodyFileURL: URL

    public init(
        descriptor: ImmutableAudioBatchDescriptor,
        bodyFileURL: URL
    ) throws {
        guard bodyFileURL.isFileURL,
              bodyFileURL.standardizedFileURL.path == bodyFileURL.path else {
            throw HarcForegroundRecordingOutboxError.invalidPlan(
                field: "backgroundBatch.bodyFileURL"
            )
        }
        self.descriptor = descriptor
        self.bodyFileURL = bodyFileURL
    }
}

/// Builds immutable background bodies without placing file/protection policy in
/// the transport target. Production HarcMobile applies its class-C and backup
/// exclusion policy before returning each batch.
public protocol HarcBackgroundAudioBatchPreparingV1: Sendable {
    func prepareBatches(
        plan: HarcForegroundRecordingUploadPlan,
        generation: UploadGeneration,
        chunks: [HarcForegroundEncodedChunk]
    ) async throws -> [HarcPreparedBackgroundAudioBatchV1]
}

public protocol HarcBackgroundUploadSchedulingV1: Sendable {
    func schedule(
        _ plan: HarcBackgroundUploadSchedulingPlanV1
    ) async throws -> SystemBackgroundTaskIdentity
}

public enum HarcBackgroundRecordingScheduleResultV1: Sendable {
    case committed(StoredVerifiedRecordingReceipt)
    case scheduled([SystemBackgroundTaskIdentity])
}

public enum HarcForegroundRecordingOutboxError: Error, Equatable, Sendable {
    case invalidPlan(field: String)
    case uploadAlreadyRunning(UploadID)
    case missingFinalizedCapture(OriginRecordingID)
    case uploadIdentityMismatch
    case securityBindingMismatch(field: String)
    case remoteStateMismatch(field: String)
    case remoteUploadTerminal(UploadReconciliationTerminalReason)
    case responseValidationFailed(String)
    case evidenceValidationFailed(String)
    case localChunkMismatch(chunkIndex: UInt32)
    case chunkRejected(chunkIndex: UInt32, reason: RejectedChunkReason)
    case missingReceiptAfterCommit
    case securityBlocked

    fileprivate var isSecurityFailure: Bool {
        switch self {
        case .securityBindingMismatch, .remoteStateMismatch,
             .responseValidationFailed, .evidenceValidationFailed:
            true
        default:
            false
        }
    }
}

/// Foreground, session-authenticated recording outbox driver.
///
/// It keeps exactly one encoded chunk in memory, uploads chunks in declaration
/// order, persists every acknowledged boundary before observing cancellation,
/// and resumes from host reconciliation plus the durable client store.
public actor HarcForegroundRecordingOutboxCoordinator {
    public typealias Clock = @Sendable () -> Date

    private let store: HarcTransferStore
    private let transport: any HarcRecordingTransferRPCTransport
    private let compatibility: HarcProtobufCompatibilityPolicy
    private let evidenceCodec: HarcRecordingEvidenceCodecV1
    private let now: Clock
    private var runningUploads = Set<UploadID>()
    private var runningOrigins = Set<OriginRecordingID>()

    public init(
        store: HarcTransferStore,
        transport: any HarcRecordingTransferRPCTransport,
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1,
        now: @escaping Clock = Date.init
    ) {
        self.store = store
        self.transport = transport
        self.compatibility = compatibility
        self.evidenceCodec = HarcRecordingEvidenceCodecV1()
        self.now = now
    }

    public func drive(
        _ plan: HarcForegroundRecordingUploadPlan,
        openedSession: HarcOpenedClientSession,
        deviceSigner: any P256DigestSigner
    ) async throws -> StoredVerifiedRecordingReceipt {
        guard !runningUploads.contains(plan.uploadID),
              !runningOrigins.contains(plan.originRecordingID) else {
            throw HarcForegroundRecordingOutboxError.uploadAlreadyRunning(
                plan.uploadID
            )
        }
        runningUploads.insert(plan.uploadID)
        runningOrigins.insert(plan.originRecordingID)
        defer {
            runningUploads.remove(plan.uploadID)
            runningOrigins.remove(plan.originRecordingID)
        }

        do {
            return try await driveOnce(
                plan,
                openedSession: openedSession,
                deviceSigner: deviceSigner
            )
        } catch is CancellationError {
            // Cancellation deliberately preserves the last synchronous store
            // boundary. A later drive replays the exact upload and manifest.
            throw CancellationError()
        } catch let error as HarcForegroundRecordingOutboxError {
            if error.isSecurityFailure {
                blockForSecurityIfPossible(origin: plan.originRecordingID)
            } else {
                failRecoverablyIfPossible(
                    origin: plan.originRecordingID,
                    error: error
                )
            }
            throw error
        } catch let error as HarcProtobufConversionError {
            blockForSecurityIfPossible(origin: plan.originRecordingID)
            throw HarcForegroundRecordingOutboxError
                .responseValidationFailed(String(reflecting: error))
        } catch let error as HarcProtocolCodecError {
            blockForSecurityIfPossible(origin: plan.originRecordingID)
            throw HarcForegroundRecordingOutboxError
                .responseValidationFailed(String(reflecting: error))
        } catch let error as HarcValidatedRecordingTransferRPCError {
            blockForSecurityIfPossible(origin: plan.originRecordingID)
            throw HarcForegroundRecordingOutboxError
                .responseValidationFailed(String(reflecting: error))
        } catch {
            failRecoverablyIfPossible(
                origin: plan.originRecordingID,
                error: error
            )
            throw error
        }
    }

    /// Authorizes and declares a finalized capture, then hands exact immutable
    /// HARCAB1 bodies to the system-managed background URLSession path. A later
    /// foreground/relaunch drive reconciles durable ACKs and performs the final
    /// manifest commit; scheduling alone never opens the cleanup gate.
    public func scheduleInBackground(
        _ plan: HarcForegroundRecordingUploadPlan,
        openedSession: HarcOpenedClientSession,
        deviceSigner: any P256DigestSigner,
        batchPreparer: any HarcBackgroundAudioBatchPreparingV1,
        scheduler: any HarcBackgroundUploadSchedulingV1
    ) async throws -> HarcBackgroundRecordingScheduleResultV1 {
        guard !runningUploads.contains(plan.uploadID),
              !runningOrigins.contains(plan.originRecordingID) else {
            throw HarcForegroundRecordingOutboxError.uploadAlreadyRunning(
                plan.uploadID
            )
        }
        runningUploads.insert(plan.uploadID)
        runningOrigins.insert(plan.originRecordingID)
        defer {
            runningUploads.remove(plan.uploadID)
            runningOrigins.remove(plan.originRecordingID)
        }

        do {
            return try await scheduleInBackgroundOnce(
                plan,
                openedSession: openedSession,
                deviceSigner: deviceSigner,
                batchPreparer: batchPreparer,
                scheduler: scheduler
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HarcForegroundRecordingOutboxError {
            if error.isSecurityFailure {
                blockForSecurityIfPossible(origin: plan.originRecordingID)
            } else {
                failRecoverablyIfPossible(
                    origin: plan.originRecordingID,
                    error: error
                )
            }
            throw error
        } catch let error as HarcProtobufConversionError {
            blockForSecurityIfPossible(origin: plan.originRecordingID)
            throw HarcForegroundRecordingOutboxError
                .responseValidationFailed(String(reflecting: error))
        } catch let error as HarcProtocolCodecError {
            blockForSecurityIfPossible(origin: plan.originRecordingID)
            throw HarcForegroundRecordingOutboxError
                .responseValidationFailed(String(reflecting: error))
        } catch let error as HarcValidatedRecordingTransferRPCError {
            blockForSecurityIfPossible(origin: plan.originRecordingID)
            throw HarcForegroundRecordingOutboxError
                .responseValidationFailed(String(reflecting: error))
        } catch {
            failRecoverablyIfPossible(
                origin: plan.originRecordingID,
                error: error
            )
            throw error
        }
    }

    private func scheduleInBackgroundOnce(
        _ plan: HarcForegroundRecordingUploadPlan,
        openedSession: HarcOpenedClientSession,
        deviceSigner: any P256DigestSigner,
        batchPreparer: any HarcBackgroundAudioBatchPreparingV1,
        scheduler: any HarcBackgroundUploadSchedulingV1
    ) async throws -> HarcBackgroundRecordingScheduleResultV1 {
        guard let storedOutbox = try store.recordingOutbox(
            for: plan.originRecordingID
        ) else {
            throw HarcForegroundRecordingOutboxError.missingFinalizedCapture(
                plan.originRecordingID
            )
        }
        guard storedOutbox.finalizedCapture.masterFileState == .present,
              storedOutbox.integrityBlock == nil else {
            throw HarcForegroundRecordingOutboxError.invalidPlan(
                field: "finalizedCaptureIntegrity"
            )
        }
        if let boundUploadID = storedOutbox.uploadID,
           boundUploadID != plan.uploadID {
            throw HarcForegroundRecordingOutboxError.uploadIdentityMismatch
        }
        if storedOutbox.stateMachine.state == .committed {
            guard let stored = try store.verifiedRecordingReceipt(
                for: plan.originRecordingID
            ), stored.uploadID == plan.uploadID,
               AdoptedTrustTuple(
                   libraryID: stored.hostTrust.libraryID,
                   hostAuthorityID: stored.hostTrust.hostAuthorityID
               ) == plan.trustTuple else {
                throw HarcForegroundRecordingOutboxError
                    .securityBindingMismatch(field: "committedReceipt")
            }
            return .committed(stored)
        }
        guard storedOutbox.stateMachine.state != .securityBlocked else {
            throw HarcForegroundRecordingOutboxError.securityBlocked
        }

        let capture = storedOutbox.finalizedCapture.capture
        let chunkedCapture = try ChunkedFinalizedCapture(
            capture: capture,
            chunks: plan.chunks.map(\.descriptor)
        )
        try chunkedCapture.validate(against: plan.frozenProfile)
        guard capture.originRecordingID == plan.originRecordingID,
              capture.producingDeviceID == store.installationDeviceID,
              deviceSigner.publicKey.deviceID == store.installationDeviceID
        else {
            throw HarcForegroundRecordingOutboxError
                .securityBindingMismatch(field: "installationDevice")
        }

        let adoption = try store.authorizingAdoption(
            for: plan.trustTuple,
            requiredScope: .recordingUploadOwn
        )
        let hostTrust = try RecordingHostTrustBinding(
            libraryID: adoption.tuple.libraryID,
            hostAuthorityID: adoption.tuple.hostAuthorityID,
            hostAuthorityPublicKeyX963: adoption.authorityPublicKeyX963
        )
        try validateSession(
            openedSession,
            adoption: adoption,
            hostTrust: hostTrust,
            deviceSigner: deviceSigner
        )

        let profilePayload = try HarcValidatedUploadProfilePayload(
            serializing: plan.frozenProfile
        )
        let protocolVersion = HarcProtocolVersion(
            major: plan.frozenProfile.protocolVersion.major,
            minor: plan.frozenProfile.protocolVersion.minor
        )
        let authorization = try HarcRecordingTransferAuthorization(
            openedSession: openedSession
        )
        let rpc = HarcValidatedRecordingTransferRPCClientV1(
            transport: transport,
            authorization: authorization,
            compatibility: compatibility
        )

        let beginRequest = try makeBeginRequest(
            plan: plan,
            capture: capture,
            profilePayload: profilePayload,
            protocolVersion: protocolVersion
        )
        let exactBeginRequest = try HarcExactProtobufPayload(
            serializingOnce: beginRequest
        ).exactBytes
        let intent = try UploadBeginIntent(
            trustTuple: plan.trustTuple,
            uploadID: plan.uploadID,
            originRecordingID: plan.originRecordingID,
            frozenProfile: plan.frozenProfile,
            chunks: try plan.chunks.map {
                try UploadBeginChunkIntent(
                    descriptor: $0.descriptor,
                    encodedFileURL: $0.encodedFileURL
                )
            },
            exactBeginRequest: exactBeginRequest
        )
        let preparation = try store.prepareUploadBeginIntent(intent)
        let durableBeginRequest = try HarcExactProtobufPayload(
            decoding: preparation.stored.intent.exactBeginRequest,
            as: Harc_V1_BeginUploadRequestV1.self
        ).message
        let priorStoredAttempt = try store.uploadAttempt(id: plan.uploadID)
        let validatedBeginRequest = try HarcValidatedBeginUploadRequestV1(
            durableBeginRequest,
            compatibility: compatibility
        )
        switch (preparation.disposition, priorStoredAttempt) {
        case (.created, nil):
            try validatedBeginRequest.validateInitialSessionCapabilities(
                openedSession.negotiatedCapabilities
            )
        case (.created, .some(_)), (.exactReplay, _):
            try validatedBeginRequest.validateCompatibleSessionCapabilities(
                openedSession.negotiatedCapabilities
            )
        }

        let beginResponse = try await rpc.beginUpload(durableBeginRequest)
        switch beginResponse.disposition {
        case .created:
            try validatedBeginRequest.validateInitialSessionCapabilities(
                openedSession.negotiatedCapabilities
            )
        case .exactReplay, .reopened, .alreadyCommitted:
            try validatedBeginRequest.validateCompatibleSessionCapabilities(
                openedSession.negotiatedCapabilities
            )
        }
        let attempt = try applyBeginResponse(
            beginResponse,
            plan: plan,
            existing: priorStoredAttempt?.attempt
        )

        if beginResponse.disposition == .alreadyCommitted {
            guard let receipt = beginResponse.existingReceipt,
                  let existingAttempt = attempt,
                  let manifest = try validatedManifest(
                    for: existingAttempt,
                    plan: plan,
                    capture: chunkedCapture,
                    hostTrust: hostTrust,
                    producingDevicePublicKey: deviceSigner.publicKey
                  ) else {
                throw HarcForegroundRecordingOutboxError
                    .remoteStateMismatch(field: "alreadyCommittedManifest")
            }
            try prepareHostCommitPending(origin: plan.originRecordingID)
            return .committed(try validateAndPersistReceipt(
                receipt.exactBytes,
                manifest: manifest,
                hostTrust: hostTrust
            ))
        }

        guard var activeAttempt = attempt,
              let beginReconciliation = beginResponse.reconciliation else {
            throw HarcForegroundRecordingOutboxError
                .remoteStateMismatch(field: "activeBegin")
        }
        activeAttempt = try synchronize(
            beginReconciliation,
            attempt: activeAttempt,
            plan: plan
        )
        try beginActiveUploadIfNeeded(origin: plan.originRecordingID)
        activeAttempt = try await declareRemainingChunks(
            attempt: activeAttempt,
            plan: plan,
            protocolVersion: protocolVersion,
            rpc: rpc
        )

        let reconciled = try await reconcile(
            attempt: activeAttempt,
            plan: plan,
            protocolVersion: protocolVersion,
            rpc: rpc
        )
        activeAttempt = reconciled.attempt
        if let exactReceipt = reconciled.exactReceipt {
            guard let manifest = try validatedManifest(
                for: activeAttempt,
                plan: plan,
                capture: chunkedCapture,
                hostTrust: hostTrust,
                producingDevicePublicKey: deviceSigner.publicKey
            ) else {
                throw HarcForegroundRecordingOutboxError
                    .remoteStateMismatch(field: "reconciledReceiptManifest")
            }
            try prepareHostCommitPending(origin: plan.originRecordingID)
            return .committed(try validateAndPersistReceipt(
                exactReceipt,
                manifest: manifest,
                hostTrust: hostTrust
            ))
        }
        guard reconciled.rejectedChunks.isEmpty else {
            throw HarcForegroundRecordingOutboxError
                .remoteStateMismatch(field: "backgroundRejectedChunks")
        }

        let durableIndexes = Set(reconciled.durableChunks.map(\.chunkIndex))
        let missing = plan.chunks.filter {
            !durableIndexes.contains($0.descriptor.chunkIndex)
        }
        guard !missing.isEmpty else {
            return .committed(try await driveOnce(
                plan,
                openedSession: openedSession,
                deviceSigner: deviceSigner
            ))
        }
        let existingSystemTasks = try activeBackgroundTaskIdentities(
            uploadID: activeAttempt.uploadID
        )
        if !existingSystemTasks.isEmpty {
            return .scheduled(existingSystemTasks)
        }
        let batches = try await batchPreparer.prepareBatches(
            plan: plan,
            generation: activeAttempt.generation,
            chunks: missing
        )
        try validatePreparedBackgroundBatches(
            batches,
            missingChunks: missing,
            attempt: activeAttempt,
            plan: plan
        )

        for chunk in missing {
            _ = try store.updateChunkOutbox(
                uploadID: activeAttempt.uploadID,
                chunkIndex: chunk.descriptor.chunkIndex
            ) { machine in
                if machine.state == .ready { try machine.schedule() }
            }
        }
        _ = try store.updateRecordingOutbox(
            for: plan.originRecordingID
        ) { machine in
            if machine.state == .authorizing {
                try machine.beginActiveUpload()
            }
            if machine.state == .activeUpload {
                try machine.scheduleBackgroundUpload()
            }
        }

        let requestedExpiry = try flooredWireDate(
            now().addingTimeInterval(7 * 24 * 60 * 60),
            field: "backgroundCapabilityExpiry"
        )
        var scheduled: [SystemBackgroundTaskIdentity] = []
        scheduled.reserveCapacity(batches.count)
        for batch in batches {
            var request = Harc_V1_MintBackgroundCapabilityRequestV1()
            request.protocol = protocolVersion.protobufV1()
            request.uploadID = Harc_V1_UploadIDV1(activeAttempt.uploadID)
            request.uploadGeneration = activeAttempt.generation.rawValue
            request.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
                exactBytes: activeAttempt.frozenProfile.profileSHA256.rawBytes
            )
            request.batchID = Harc_V1_AudioBatchIDV1(
                batch.descriptor.batchID
            )
            request.chunks = try batch.descriptor.chunks.map { descriptor in
                var binding = Harc_V1_BackgroundChunkBindingV1()
                binding.chunkIndex = descriptor.chunkIndex
                binding.encodedSha256 = try Harc_V1_SHA256DigestV1(
                    exactBytes: descriptor.encodedSHA256.rawBytes
                )
                return binding
            }
            request.exactBatchBodySha256 = try Harc_V1_SHA256DigestV1(
                exactBytes: batch.descriptor.exactBodySHA256.rawBytes
            )
            request.exactBatchBodyLength =
                batch.descriptor.exactBodyByteLength
            request.requestedExpiresAtUnixMs = try exactUnixMilliseconds(
                requestedExpiry,
                field: "backgroundCapabilityExpiry"
            )
            let capability = try await rpc
                .mintBackgroundUploadAuthorization(request)
            let schedulingPlan = try HarcBackgroundUploadSchedulingPlanV1(
                descriptor: batch.descriptor,
                bodyFileURL: batch.bodyFileURL,
                capabilityResponse: capability,
                hostTrust: hostTrust
            )
            scheduled.append(try await scheduler.schedule(schedulingPlan))
        }
        return .scheduled(scheduled)
    }

    private func driveOnce(
        _ plan: HarcForegroundRecordingUploadPlan,
        openedSession: HarcOpenedClientSession,
        deviceSigner: any P256DigestSigner
    ) async throws -> StoredVerifiedRecordingReceipt {
        guard let storedOutbox = try store.recordingOutbox(
            for: plan.originRecordingID
        ) else {
            throw HarcForegroundRecordingOutboxError.missingFinalizedCapture(
                plan.originRecordingID
            )
        }
        guard storedOutbox.finalizedCapture.masterFileState == .present,
              storedOutbox.integrityBlock == nil else {
            throw HarcForegroundRecordingOutboxError.invalidPlan(
                field: "finalizedCaptureIntegrity"
            )
        }
        if let boundUploadID = storedOutbox.uploadID,
           boundUploadID != plan.uploadID {
            throw HarcForegroundRecordingOutboxError.uploadIdentityMismatch
        }
        if storedOutbox.stateMachine.state == .committed {
            guard let stored = try store.verifiedRecordingReceipt(
                for: plan.originRecordingID
            ), stored.uploadID == plan.uploadID,
               AdoptedTrustTuple(
                   libraryID: stored.hostTrust.libraryID,
                   hostAuthorityID: stored.hostTrust.hostAuthorityID
               ) == plan.trustTuple else {
                throw HarcForegroundRecordingOutboxError
                    .securityBindingMismatch(field: "committedReceipt")
            }
            return stored
        }
        guard storedOutbox.stateMachine.state != .securityBlocked else {
            throw HarcForegroundRecordingOutboxError.securityBlocked
        }

        let capture = storedOutbox.finalizedCapture.capture
        let chunkedCapture = try ChunkedFinalizedCapture(
            capture: capture,
            chunks: plan.chunks.map(\.descriptor)
        )
        try chunkedCapture.validate(against: plan.frozenProfile)
        guard capture.originRecordingID == plan.originRecordingID,
              capture.producingDeviceID == store.installationDeviceID,
              deviceSigner.publicKey.deviceID == store.installationDeviceID
        else {
            throw HarcForegroundRecordingOutboxError
                .securityBindingMismatch(field: "installationDevice")
        }

        let adoption = try store.authorizingAdoption(
            for: plan.trustTuple,
            requiredScope: .recordingUploadOwn
        )
        let hostTrust = try RecordingHostTrustBinding(
            libraryID: adoption.tuple.libraryID,
            hostAuthorityID: adoption.tuple.hostAuthorityID,
            hostAuthorityPublicKeyX963: adoption.authorityPublicKeyX963
        )
        try validateSession(
            openedSession,
            adoption: adoption,
            hostTrust: hostTrust,
            deviceSigner: deviceSigner
        )

        let profilePayload = try HarcValidatedUploadProfilePayload(
            serializing: plan.frozenProfile
        )
        let protocolVersion = HarcProtocolVersion(
            major: plan.frozenProfile.protocolVersion.major,
            minor: plan.frozenProfile.protocolVersion.minor
        )
        let authorization = try HarcRecordingTransferAuthorization(
            openedSession: openedSession
        )
        let rpc = HarcValidatedRecordingTransferRPCClientV1(
            transport: transport,
            authorization: authorization,
            compatibility: compatibility
        )

        let beginRequest = try makeBeginRequest(
            plan: plan,
            capture: capture,
            profilePayload: profilePayload,
            protocolVersion: protocolVersion
        )
        let exactBeginRequest = try HarcExactProtobufPayload(
            serializingOnce: beginRequest
        ).exactBytes
        let intent = try UploadBeginIntent(
            trustTuple: plan.trustTuple,
            uploadID: plan.uploadID,
            originRecordingID: plan.originRecordingID,
            frozenProfile: plan.frozenProfile,
            chunks: try plan.chunks.map {
                try UploadBeginChunkIntent(
                    descriptor: $0.descriptor,
                    encodedFileURL: $0.encodedFileURL
                )
            },
            exactBeginRequest: exactBeginRequest
        )
        let preparation = try store.prepareUploadBeginIntent(intent)
        let durableBeginRequest = try HarcExactProtobufPayload(
            decoding: preparation.stored.intent.exactBeginRequest,
            as: Harc_V1_BeginUploadRequestV1.self
        ).message
        let priorStoredAttempt = try store.uploadAttempt(id: plan.uploadID)
        let validatedBeginRequest = try HarcValidatedBeginUploadRequestV1(
            durableBeginRequest,
            compatibility: compatibility
        )
        switch (preparation.disposition, priorStoredAttempt) {
        case (.created, nil):
            try validatedBeginRequest.validateInitialSessionCapabilities(
                openedSession.negotiatedCapabilities
            )
        case (.created, .some(_)), (.exactReplay, _):
            try validatedBeginRequest.validateCompatibleSessionCapabilities(
                openedSession.negotiatedCapabilities
            )
        }

        let beginResponse = try await rpc.beginUpload(durableBeginRequest)
        switch beginResponse.disposition {
        case .created:
            try validatedBeginRequest.validateInitialSessionCapabilities(
                openedSession.negotiatedCapabilities
            )
        case .exactReplay, .reopened, .alreadyCommitted:
            try validatedBeginRequest.validateCompatibleSessionCapabilities(
                openedSession.negotiatedCapabilities
            )
        }
        let attempt = try applyBeginResponse(
            beginResponse,
            plan: plan,
            existing: priorStoredAttempt?.attempt
        )

        if beginResponse.disposition == .alreadyCommitted {
            guard let receipt = beginResponse.existingReceipt,
                  let existingAttempt = attempt,
                  let manifest = try validatedManifest(
                    for: existingAttempt,
                    plan: plan,
                    capture: chunkedCapture,
                    hostTrust: hostTrust,
                    producingDevicePublicKey: deviceSigner.publicKey
                  ) else {
                throw HarcForegroundRecordingOutboxError
                    .remoteStateMismatch(field: "alreadyCommittedManifest")
            }
            try prepareHostCommitPending(origin: plan.originRecordingID)
            return try validateAndPersistReceipt(
                receipt.exactBytes,
                manifest: manifest,
                hostTrust: hostTrust
            )
        }

        guard var activeAttempt = attempt,
              let beginReconciliation = beginResponse.reconciliation else {
            throw HarcForegroundRecordingOutboxError
                .remoteStateMismatch(field: "activeBegin")
        }
        activeAttempt = try synchronize(
            beginReconciliation,
            attempt: activeAttempt,
            plan: plan
        )
        try beginActiveUploadIfNeeded(origin: plan.originRecordingID)

        activeAttempt = try await declareRemainingChunks(
            attempt: activeAttempt,
            plan: plan,
            protocolVersion: protocolVersion,
            rpc: rpc
        )

        let beforeUpload = try await reconcile(
            attempt: activeAttempt,
            plan: plan,
            protocolVersion: protocolVersion,
            rpc: rpc
        )
        activeAttempt = beforeUpload.attempt
        if let exactReceipt = beforeUpload.exactReceipt {
            guard let manifest = try validatedManifest(
                for: activeAttempt,
                plan: plan,
                capture: chunkedCapture,
                hostTrust: hostTrust,
                producingDevicePublicKey: deviceSigner.publicKey
            ) else {
                throw HarcForegroundRecordingOutboxError
                    .remoteStateMismatch(field: "reconciledReceiptManifest")
            }
            try prepareHostCommitPending(origin: plan.originRecordingID)
            return try validateAndPersistReceipt(
                exactReceipt,
                manifest: manifest,
                hostTrust: hostTrust
            )
        }

        try await uploadMissingChunks(
            attempt: activeAttempt,
            plan: plan,
            protocolVersion: protocolVersion,
            rpc: rpc
        )

        let afterUpload = try await reconcile(
            attempt: activeAttempt,
            plan: plan,
            protocolVersion: protocolVersion,
            rpc: rpc
        )
        activeAttempt = afterUpload.attempt
        if let exactReceipt = afterUpload.exactReceipt {
            guard let manifest = try validatedManifest(
                for: activeAttempt,
                plan: plan,
                capture: chunkedCapture,
                hostTrust: hostTrust,
                producingDevicePublicKey: deviceSigner.publicKey
            ) else {
                throw HarcForegroundRecordingOutboxError
                    .remoteStateMismatch(field: "postUploadReceiptManifest")
            }
            try prepareHostCommitPending(origin: plan.originRecordingID)
            return try validateAndPersistReceipt(
                exactReceipt,
                manifest: manifest,
                hostTrust: hostTrust
            )
        }
        let durableIndexes = Set(afterUpload.durableChunks.map(\.chunkIndex))
        guard afterUpload.rejectedChunks.isEmpty,
              durableIndexes == Set(plan.chunks.map(\.descriptor.chunkIndex))
        else {
            throw HarcForegroundRecordingOutboxError
                .remoteStateMismatch(field: "durableChunkSet")
        }

        let manifest = try bindOrValidateManifest(
            attempt: &activeAttempt,
            plan: plan,
            capture: chunkedCapture,
            hostTrust: hostTrust,
            producingDeviceSigner: deviceSigner,
            protocolVersion: protocolVersion
        )
        try prepareHostCommitPending(origin: plan.originRecordingID)

        var commitRequest = Harc_V1_CommitUploadRequestV1()
        commitRequest.protocol = protocolVersion.protobufV1()
        commitRequest.uploadID = Harc_V1_UploadIDV1(plan.uploadID)
        commitRequest.uploadGeneration = activeAttempt.generation.rawValue
        commitRequest.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: plan.frozenProfile.profileSHA256.rawBytes
        )
        commitRequest.exactSignedRecordingManifest =
            Harc_V1_ExactSignedObjectV1(manifest.exactManifestObject)
        _ = try HarcValidatedCommitUploadRequestV1(
            commitRequest,
            compatibility: compatibility
        )

        do {
            let committed = try await rpc.commitUpload(commitRequest)
            return try validateAndPersistReceipt(
                committed.receipt.exactBytes,
                manifest: manifest,
                hostTrust: hostTrust
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HarcProtobufConversionError {
            throw HarcForegroundRecordingOutboxError
                .responseValidationFailed(String(reflecting: error))
        } catch let error as HarcProtocolCodecError {
            throw HarcForegroundRecordingOutboxError
                .responseValidationFailed(String(reflecting: error))
        } catch let error as HarcValidatedRecordingTransferRPCError {
            throw HarcForegroundRecordingOutboxError
                .responseValidationFailed(String(reflecting: error))
        } catch {
            // A transport failure after the host accepted Commit is ambiguous.
            // Resolve only through a separately request-bound status response.
            if let recovered = try await receiptFromStatus(
                plan: plan,
                protocolVersion: protocolVersion,
                rpc: rpc
            ) {
                return try validateAndPersistReceipt(
                    recovered,
                    manifest: manifest,
                    hostTrust: hostTrust
                )
            }
            throw HarcForegroundRecordingOutboxError
                .missingReceiptAfterCommit
        }
    }

    private func validateSession(
        _ session: HarcOpenedClientSession,
        adoption: ActiveAdoptionSnapshot,
        hostTrust: RecordingHostTrustBinding,
        deviceSigner: any P256DigestSigner
    ) throws {
        guard session.grant.status == .active,
              session.grant.hostTrust == hostTrust,
              session.grant.grantID == adoption.grant.grantID,
              session.grant.registryEpoch == adoption.grant.registryEpoch,
              session.grant.deviceID == adoption.grant.deviceID,
              session.grant.devicePublicKey == deviceSigner.publicKey,
              adoption.grant.devicePublicKeyX963 == deviceSigner.publicKey.rawBytes,
              session.grant.scopes.contains(.recordingUploadOwn)
        else {
            throw HarcForegroundRecordingOutboxError
                .securityBindingMismatch(field: "openedSession")
        }
    }

    private func makeBeginRequest(
        plan: HarcForegroundRecordingUploadPlan,
        capture: FinalizedCapture,
        profilePayload: HarcValidatedUploadProfilePayload,
        protocolVersion: HarcProtocolVersion
    ) throws -> Harc_V1_BeginUploadRequestV1 {
        var request = Harc_V1_BeginUploadRequestV1()
        request.protocol = protocolVersion.protobufV1()
        request.libraryID = Harc_V1_LibraryIDV1(plan.trustTuple.libraryID)
        request.hostAuthorityID = Harc_V1_HostAuthorityIDV1(
            plan.trustTuple.hostAuthorityID
        )
        request.uploadID = Harc_V1_UploadIDV1(plan.uploadID)
        request.originRecordingID = Harc_V1_OriginRecordingIDV1(
            plan.originRecordingID
        )
        request.producingDeviceID = Harc_V1_DeviceIDV1(
            capture.producingDeviceID
        )
        request.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(
            capture.canonicalFormat
        )
        request.captureStartedAtUnixMs = try canonicalUnixMilliseconds(
            capture.captureStartedAt,
            field: "captureStartedAt"
        )
        request.captureStartedMonotonicNanoseconds =
            capture.captureStartedMonotonicNanoseconds
        request.exactUploadProfilePayload = profilePayload.exactPayload.exactBytes
        request.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: plan.frozenProfile.profileSHA256.rawBytes
        )
        _ = try HarcValidatedBeginUploadRequestV1(
            request,
            compatibility: compatibility
        )
        return request
    }

    private func applyBeginResponse(
        _ response: HarcValidatedBeginUploadResponseV1,
        plan: HarcForegroundRecordingUploadPlan,
        existing: UploadAttempt?
    ) throws -> UploadAttempt? {
        if response.disposition == .alreadyCommitted {
            guard let existing else {
                throw HarcForegroundRecordingOutboxError
                    .remoteStateMismatch(field: "missingCommittedAttempt")
            }
            try existing.validateExactBeginReplay(
                uploadID: plan.uploadID,
                ownerDeviceID: plan.originRecordingID.deviceID,
                originRecordingID: plan.originRecordingID,
                frozenProfile: plan.frozenProfile
            )
            return existing
        }
        guard let generation = response.generation,
              let firstBeganAt = response.firstBeganAt,
              let generationBeganAt = response.generationBeganAt,
              let expiresAt = response.generationExpiresAt else {
            throw HarcForegroundRecordingOutboxError
                .remoteStateMismatch(field: "beginGeneration")
        }

        var attempt: UploadAttempt
        if var existing {
            try existing.validateExactBeginReplay(
                uploadID: plan.uploadID,
                ownerDeviceID: plan.originRecordingID.deviceID,
                originRecordingID: plan.originRecordingID,
                frozenProfile: plan.frozenProfile
            )
            switch response.disposition {
            case .created:
                throw HarcForegroundRecordingOutboxError
                    .remoteStateMismatch(field: "createdReplay")
            case .exactReplay:
                guard existing.generation == generation,
                      existing.firstBeganAt == firstBeganAt,
                      existing.generationBeganAt == generationBeganAt,
                      existing.generationExpiresAt == expiresAt else {
                    throw HarcForegroundRecordingOutboxError
                        .remoteStateMismatch(field: "exactReplayGeneration")
                }
            case .reopened:
                guard try existing.generation.next() == generation,
                      existing.firstBeganAt == firstBeganAt,
                      generationBeganAt >= existing.generationExpiresAt else {
                    throw HarcForegroundRecordingOutboxError
                        .remoteStateMismatch(field: "reopenedGeneration")
                }
                try existing.reopen(
                    at: generationBeganAt,
                    grantExpiresAt: expiresAt
                )
                guard existing.generationBeganAt == generationBeganAt,
                      existing.generationExpiresAt == expiresAt else {
                    throw HarcForegroundRecordingOutboxError
                        .remoteStateMismatch(field: "reopenedExpiry")
                }
            case .alreadyCommitted:
                throw HarcForegroundRecordingOutboxError
                    .remoteStateMismatch(field: "beginDisposition")
            }
            attempt = existing
        } else {
            guard response.disposition == .created
                    || response.disposition == .exactReplay
                    || response.disposition == .reopened,
                  response.disposition != .created
                    || generation == .initial else {
                throw HarcForegroundRecordingOutboxError
                    .remoteStateMismatch(field: "missingInitialAttempt")
            }
            attempt = try UploadAttempt.recoverActive(
                uploadID: plan.uploadID,
                ownerDeviceID: plan.originRecordingID.deviceID,
                originRecordingID: plan.originRecordingID,
                frozenProfile: plan.frozenProfile,
                firstBeganAt: firstBeganAt,
                generation: generation,
                generationBeganAt: generationBeganAt,
                generationExpiresAt: expiresAt
            )
        }
        try store.persistUploadAttempt(attempt, for: plan.trustTuple)
        return attempt
    }

    private func synchronize(
        _ response: HarcValidatedReconcileUploadResponseV1,
        attempt originalAttempt: UploadAttempt,
        plan: HarcForegroundRecordingUploadPlan
    ) throws -> UploadAttempt {
        var attempt = originalAttempt
        let remote = response.reconciliation
        guard remote.uploadID == attempt.uploadID,
              remote.ownerDeviceID == attempt.ownerDeviceID,
              remote.originRecordingID == attempt.originRecordingID,
              remote.uploadProfileSHA256 == attempt.frozenProfile.profileSHA256,
              remote.generation == attempt.generation,
              remote.firstBeganAt == attempt.firstBeganAt,
              remote.generationBeganAt == attempt.generationBeganAt,
              remote.generationExpiresAt == attempt.generationExpiresAt,
              remote.declarations.count <= plan.chunks.count,
              remote.declarations == Array(
                plan.chunks.map(\.descriptor).prefix(remote.declarations.count)
              ),
              attempt.declarations.descriptors == Array(
                remote.declarations.prefix(attempt.declarations.descriptors.count)
              ) else {
            throw HarcForegroundRecordingOutboxError
                .remoteStateMismatch(field: "reconciliationIdentity")
        }

        if remote.declarations.count > attempt.declarations.descriptors.count {
            let recovered = Array(
                remote.declarations.dropFirst(
                    attempt.declarations.descriptors.count
                )
            )
            for batch in recovered.chunked(
                maximumCount: TransferLimits.declaredChunksPerCall
            ) {
                _ = try attempt.declare(
                    batch,
                    generation: attempt.generation,
                    at: attempt.generationBeganAt
                )
            }
            try store.persistUploadAttempt(attempt, for: plan.trustTuple)
        }

        let durableIndexes = Set(remote.durableChunks.map(\.chunkIndex))
        var storedChunks = try store.chunks(uploadID: attempt.uploadID)
        var storedByIndex = Dictionary(
            uniqueKeysWithValues: storedChunks.map {
                ($0.descriptor.chunkIndex, $0)
            }
        )
        for declared in remote.declarations where storedByIndex[declared.chunkIndex] == nil {
            guard let planned = plan.chunks.first(where: {
                $0.descriptor.chunkIndex == declared.chunkIndex
            }) else {
                throw HarcForegroundRecordingOutboxError
                    .remoteStateMismatch(field: "recoveredChunkFile")
            }
            var machine = ChunkOutboxStateMachine()
            try machine.beginEncoding()
            try machine.markReady()
            if durableIndexes.contains(declared.chunkIndex) {
                try machine.schedule()
            }
            try store.persistEncodedChunk(
                uploadID: attempt.uploadID,
                descriptor: declared,
                encodedFileURL: planned.encodedFileURL,
                stateMachine: machine
            )
        }

        storedChunks = try store.chunks(uploadID: attempt.uploadID)
        storedByIndex = Dictionary(
            uniqueKeysWithValues: storedChunks.map {
                ($0.descriptor.chunkIndex, $0)
            }
        )
        let remoteDurableByIndex = Dictionary(
            uniqueKeysWithValues: remote.durableChunks.map {
                ($0.chunkIndex, $0)
            }
        )
        for stored in storedChunks
            where stored.stateMachine.state == .durableAtHost {
            guard let remoteDurable = remoteDurableByIndex[
                stored.descriptor.chunkIndex
            ], remoteDurable.chunkID == stored.descriptor.chunkID,
               remoteDurable.encodedSHA256 == stored.descriptor.encodedSHA256 else {
                throw HarcForegroundRecordingOutboxError
                    .remoteStateMismatch(field: "durableChunkRollback")
            }
        }

        switch remote.terminalReason {
        case .expired?:
            throw HarcForegroundRecordingOutboxError
                .remoteUploadTerminal(.expired)
        case .abandoned?:
            throw HarcForegroundRecordingOutboxError
                .remoteUploadTerminal(.abandoned)
        case .declarationConflict?:
            throw HarcForegroundRecordingOutboxError
                .remoteStateMismatch(field: "terminalUpload")
        case .committed?:
            guard remote.existingReceipt != nil else {
                throw HarcForegroundRecordingOutboxError
                    .remoteStateMismatch(field: "committedReceipt")
            }
        case nil:
            break
        }

        let localManifestSHA256 = attempt.boundManifest?.objectSHA256
        guard remote.boundManifestObjectSHA256 == nil
                || remote.boundManifestObjectSHA256 == localManifestSHA256 else {
            throw HarcForegroundRecordingOutboxError
                .remoteStateMismatch(field: "boundManifest")
        }
        if remote.boundManifestObjectSHA256 == localManifestSHA256 {
            try store.applyUploadReconciliation(remote)
        } else {
            guard remote.rejectedChunks.isEmpty else {
                throw HarcForegroundRecordingOutboxError
                    .remoteStateMismatch(field: "rejectedBoundUpload")
            }
            // A locally persisted manifest can be ahead of a cancelled Commit.
            // Reconcile the independently durable chunks without pretending the
            // host has bound that manifest yet.
            for durable in remote.durableChunks {
                guard let stored = storedByIndex[durable.chunkIndex],
                      stored.descriptor.chunkID == durable.chunkID,
                      stored.descriptor.encodedSHA256 == durable.encodedSHA256
                else {
                    throw HarcForegroundRecordingOutboxError
                        .remoteStateMismatch(field: "durableChunk")
                }
                if stored.stateMachine.state != .durableAtHost {
                    _ = try store.updateChunkOutbox(
                        uploadID: attempt.uploadID,
                        chunkIndex: durable.chunkIndex
                    ) { machine in
                        if machine.state == .failedRecoverable {
                            try machine.retryRecoverable()
                        }
                        if machine.state == .ready {
                            try machine.schedule()
                        }
                        try machine.markDurableAtHost()
                    }
                }
            }
        }
        return attempt
    }

    private func declareRemainingChunks(
        attempt originalAttempt: UploadAttempt,
        plan: HarcForegroundRecordingUploadPlan,
        protocolVersion: HarcProtocolVersion,
        rpc: HarcValidatedRecordingTransferRPCClientV1
    ) async throws -> UploadAttempt {
        var attempt = originalAttempt
        let allDescriptors = plan.chunks.map(\.descriptor)
        while attempt.declarations.descriptors.count < allDescriptors.count {
            try Task.checkCancellation()
            let start = attempt.declarations.descriptors.count
            let end = min(
                start + TransferLimits.declaredChunksPerCall,
                allDescriptors.count
            )
            let batch = Array(allDescriptors[start ..< end])
            var request = Harc_V1_DeclareChunksRequestV1()
            request.protocol = protocolVersion.protobufV1()
            request.uploadID = Harc_V1_UploadIDV1(attempt.uploadID)
            request.uploadGeneration = attempt.generation.rawValue
            request.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
                exactBytes: attempt.frozenProfile.profileSHA256.rawBytes
            )
            request.descriptors = try batch.map(
                Harc_V1_ChunkDescriptorV1.init
            )
            let response = try await rpc.declareChunks(request)
            switch response.disposition {
            case .appended(let firstIndex, let count):
                guard firstIndex == batch[0].chunkIndex,
                      count == UInt32(batch.count) else {
                    throw HarcForegroundRecordingOutboxError
                        .remoteStateMismatch(field: "declaredRange")
                }
            case .exactReplay:
                break
            case .closed, .conflictBlocked(_):
                throw HarcForegroundRecordingOutboxError
                    .remoteStateMismatch(field: "declarationDisposition")
            }
            // No cancellation point is allowed between an accepted response
            // and this durable local replay boundary.
            _ = try attempt.declare(
                batch,
                generation: attempt.generation,
                at: attempt.generationBeganAt
            )
            try store.persistUploadAttempt(attempt, for: plan.trustTuple)
            for offset in start ..< end {
                var machine = ChunkOutboxStateMachine()
                try machine.beginEncoding()
                try machine.markReady()
                try store.persistEncodedChunk(
                    uploadID: attempt.uploadID,
                    descriptor: plan.chunks[offset].descriptor,
                    encodedFileURL: plan.chunks[offset].encodedFileURL,
                    stateMachine: machine
                )
            }
        }
        return attempt
    }

    private struct ReconciledAttempt {
        let attempt: UploadAttempt
        let durableChunks: [DurableChunkStatus]
        let rejectedChunks: [RejectedChunkStatus]
        let exactReceipt: Data?
    }

    private func reconcile(
        attempt: UploadAttempt,
        plan: HarcForegroundRecordingUploadPlan,
        protocolVersion: HarcProtocolVersion,
        rpc: HarcValidatedRecordingTransferRPCClientV1
    ) async throws -> ReconciledAttempt {
        var request = Harc_V1_ReconcileUploadRequestV1()
        request.protocol = protocolVersion.protobufV1()
        request.uploadID = Harc_V1_UploadIDV1(attempt.uploadID)
        request.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: attempt.frozenProfile.profileSHA256.rawBytes
        )
        let response = try await rpc.reconcileUpload(request)
        let synchronized = try synchronize(
            response,
            attempt: attempt,
            plan: plan
        )
        return ReconciledAttempt(
            attempt: synchronized,
            durableChunks: response.durableChunks,
            rejectedChunks: response.rejectedChunks,
            exactReceipt: response.existingReceipt?.exactBytes
        )
    }

    private func uploadMissingChunks(
        attempt: UploadAttempt,
        plan: HarcForegroundRecordingUploadPlan,
        protocolVersion: HarcProtocolVersion,
        rpc: HarcValidatedRecordingTransferRPCClientV1
    ) async throws {
        let storedChunks = try store.chunks(uploadID: attempt.uploadID)
        let byIndex = Dictionary(
            uniqueKeysWithValues: storedChunks.map {
                ($0.descriptor.chunkIndex, $0)
            }
        )
        for planned in plan.chunks {
            let index = planned.descriptor.chunkIndex
            guard var stored = byIndex[index],
                  stored.descriptor == planned.descriptor,
                  stored.encodedFileURL == planned.encodedFileURL else {
                throw HarcForegroundRecordingOutboxError
                    .invalidPlan(field: "storedChunk")
            }
            if stored.stateMachine.state == .durableAtHost { continue }
            if stored.stateMachine.state == .failedRecoverable {
                _ = try store.updateChunkOutbox(
                    uploadID: attempt.uploadID,
                    chunkIndex: index
                ) { try $0.retryRecoverable() }
                stored = try requireStoredChunk(
                    uploadID: attempt.uploadID,
                    chunkIndex: index
                )
            }
            switch stored.stateMachine.state {
            case .ready, .scheduled:
                _ = try store.updateChunkOutbox(
                    uploadID: attempt.uploadID,
                    chunkIndex: index
                ) { try $0.beginSending() }
            case .sending:
                break
            case .pending, .encoding, .durableAtHost, .failedRecoverable:
                throw HarcForegroundRecordingOutboxError
                    .invalidPlan(field: "chunkOutboxState")
            }

            do {
                try Task.checkCancellation()
                let bytes = try readAndValidateChunk(planned)
                var request = Harc_V1_UploadChunkRequestV1()
                request.protocol = protocolVersion.protobufV1()
                request.uploadID = Harc_V1_UploadIDV1(attempt.uploadID)
                request.uploadGeneration = attempt.generation.rawValue
                request.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
                    exactBytes: attempt.frozenProfile.profileSHA256.rawBytes
                )
                request.chunkIndex = index
                request.chunkID = Harc_V1_ChunkIDV1(planned.descriptor.chunkID)
                request.encodedByteLength = planned.descriptor.encodedByteLength
                request.encodedSha256 = try Harc_V1_SHA256DigestV1(
                    exactBytes: planned.descriptor.encodedSHA256.rawBytes
                )
                request.encodedChunk = bytes

                let store = self.store
                let uploadID = attempt.uploadID
                try await rpc.uploadChunk(request) { response in
                    switch response.result {
                    case .acknowledgement:
                        guard response.acknowledgement != nil else {
                            throw HarcForegroundRecordingOutboxError
                                .responseValidationFailed(
                                    "missing acknowledgement"
                                )
                        }
                        _ = try store.updateChunkOutbox(
                            uploadID: uploadID,
                            chunkIndex: index
                        ) { machine in
                            if machine.state != .durableAtHost {
                                try machine.markDurableAtHost()
                            }
                        }
                    case .rejection(let rejection):
                        _ = try store.updateChunkOutbox(
                            uploadID: uploadID,
                            chunkIndex: index
                        ) { machine in
                            try machine.failRecoverably(
                                TransferFailure(
                                    code: "host-rejected-chunk",
                                    detail: rejection.reason.rawValue
                                ),
                                retryFrom: .ready
                            )
                        }
                        throw HarcForegroundRecordingOutboxError.chunkRejected(
                            chunkIndex: index,
                            reason: rejection.reason
                        )
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as HarcForegroundRecordingOutboxError
                where error.isSecurityFailure {
                throw error
            } catch let error as HarcProtobufConversionError {
                throw error
            } catch let error as HarcProtocolCodecError {
                throw error
            } catch let error as HarcValidatedRecordingTransferRPCError {
                throw error
            } catch {
                failChunkRecoverablyIfSending(
                    uploadID: attempt.uploadID,
                    chunkIndex: index,
                    error: error
                )
                throw error
            }
        }
    }

    private func bindOrValidateManifest(
        attempt: inout UploadAttempt,
        plan: HarcForegroundRecordingUploadPlan,
        capture: ChunkedFinalizedCapture,
        hostTrust: RecordingHostTrustBinding,
        producingDeviceSigner: any P256DigestSigner,
        protocolVersion: HarcProtocolVersion
    ) throws -> ValidatedRecordingManifestEvidence {
        if let existing = try validatedManifest(
            for: attempt,
            plan: plan,
            capture: capture,
            hostTrust: hostTrust,
            producingDevicePublicKey: producingDeviceSigner.publicKey
        ) {
            return existing
        }

        let manifestIssuedAt = try flooredWireDate(
            now(),
            field: "manifestIssuedAt"
        )
        let issuedAt = try exactUnixMilliseconds(
            manifestIssuedAt,
            field: "manifestIssuedAt"
        )
        var value = Harc_V1_RecordingManifestV1()
        value.protocol = protocolVersion.protobufV1()
        value.manifestVersion = 1
        value.issuedAtUnixMs = issuedAt
        value.libraryID = Harc_V1_LibraryIDV1(hostTrust.libraryID)
        value.hostAuthorityID = Harc_V1_HostAuthorityIDV1(
            hostTrust.hostAuthorityID
        )
        value.originRecordingID = Harc_V1_OriginRecordingIDV1(
            plan.originRecordingID
        )
        value.uploadID = Harc_V1_UploadIDV1(plan.uploadID)
        value.producingDeviceID = Harc_V1_DeviceIDV1(
            capture.capture.producingDeviceID
        )
        value.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: plan.frozenProfile.profileSHA256.rawBytes
        )
        value.descriptorSchemaID = plan.frozenProfile.descriptorSchema.rawValue
        value.encoding = Harc_V1_LosslessEncodingConfigurationV1(
            plan.frozenProfile.encoding
        )
        value.captureStartedAtUnixMs = try canonicalUnixMilliseconds(
            capture.capture.captureStartedAt,
            field: "manifestCaptureStartedAt"
        )
        value.captureEndedAtUnixMs = try canonicalUnixMilliseconds(
            capture.capture.captureEndedAt,
            field: "manifestCaptureEndedAt"
        )
        value.captureStartedMonotonicNanoseconds =
            capture.capture.captureStartedMonotonicNanoseconds
        value.captureEndedMonotonicNanoseconds =
            capture.capture.captureEndedMonotonicNanoseconds
        value.finalizationReason = finalizationReason(
            capture.capture.finalizationReason
        )
        value.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(
            capture.capture.canonicalFormat
        )
        value.totalCanonicalFrames = capture.capture.totalCanonicalFrames
        value.totalCanonicalBytes = capture.capture.totalCanonicalBytes
        value.canonicalPcmSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: capture.capture.canonicalPCMSHA256.rawBytes
        )
        value.chunks = try capture.chunks.map(
            Harc_V1_ChunkDescriptorV1.init
        )
        value.discontinuities = try capture.capture.discontinuities.map(
            Harc_V1_CaptureDiscontinuityV1.init
        )
        value.processingArtifactObjectIds = []

        let exactPayload = try HarcExactProtobufPayload(
            serializingOnce: value
        )
        let header = try HarcSignedEnvelopeV1(
            messageType: .recordingManifest,
            protocolVersion: protocolVersion,
            libraryID: hostTrust.libraryID,
            hostAuthorityID: hostTrust.hostAuthorityID,
            signerDeviceID: producingDeviceSigner.publicKey.deviceID,
            grantID: nil,
            grantEpoch: 0,
            operationID: plan.uploadID.rawValue,
            issuedAtUnixMilliseconds: issuedAt,
            expiresAtUnixMilliseconds: nil,
            payloadType: .recordingManifest,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(
                exactPayload.exactBytes
            ),
            versionPolicy: compatibility.versionPolicy
        )
        let signed = try HarcSignedObjectV1.signRegistered(
            header: header,
            exactPayloadBytes: exactPayload.exactBytes,
            payloadBindings: HarcSignedPayloadBindingsV1(
                protocolVersion: protocolVersion,
                libraryID: hostTrust.libraryID,
                hostAuthorityID: hostTrust.hostAuthorityID,
                issuedAtUnixMilliseconds: issuedAt,
                signerDeviceID: producingDeviceSigner.publicKey.deviceID,
                operationID: plan.uploadID.rawValue
            ),
            using: producingDeviceSigner
        )
        let validated = try validateManifestEvidence(
            signed.exactFramedBytes,
            plan: plan,
            capture: capture,
            hostTrust: hostTrust,
            producingDevicePublicKey: producingDeviceSigner.publicKey
        )
        _ = try attempt.bindFinalManifest(
            using: validated,
            generation: attempt.generation,
            at: attempt.generationBeganAt
        )
        // The exact signed bytes are durable before Commit can observe them.
        try store.persistUploadAttempt(attempt, for: plan.trustTuple)
        return validated
    }

    private func validatedManifest(
        for attempt: UploadAttempt,
        plan: HarcForegroundRecordingUploadPlan,
        capture: ChunkedFinalizedCapture,
        hostTrust: RecordingHostTrustBinding,
        producingDevicePublicKey: P256X963PublicKey
    ) throws -> ValidatedRecordingManifestEvidence? {
        guard let bound = attempt.boundManifest else { return nil }
        return try validateManifestEvidence(
            bound.exactBytes,
            plan: plan,
            capture: capture,
            hostTrust: hostTrust,
            producingDevicePublicKey: producingDevicePublicKey
        )
    }

    private func validateManifestEvidence(
        _ exactBytes: Data,
        plan: HarcForegroundRecordingUploadPlan,
        capture: ChunkedFinalizedCapture,
        hostTrust: RecordingHostTrustBinding,
        producingDevicePublicKey: P256X963PublicKey
    ) throws -> ValidatedRecordingManifestEvidence {
        do {
            let canonicalCapture = try wireCanonicalCapture(capture)
            let evidence = try evidenceCodec.validateRecordingManifest(
                exactSignedManifestBytes: exactBytes,
                hostTrust: hostTrust,
                producingDevicePublicKey: producingDevicePublicKey
            )
            guard evidence.uploadID == plan.uploadID,
                  evidence.originRecordingID == plan.originRecordingID,
                  evidence.uploadProfileSHA256
                    == plan.frozenProfile.profileSHA256,
                  evidence.finalizedCapture == canonicalCapture else {
                throw HarcForegroundRecordingOutboxError
                    .evidenceValidationFailed("manifest bindings")
            }
            return evidence
        } catch let error as HarcForegroundRecordingOutboxError {
            throw error
        } catch {
            throw HarcForegroundRecordingOutboxError
                .evidenceValidationFailed(String(reflecting: error))
        }
    }

    private func validateAndPersistReceipt(
        _ exactBytes: Data,
        manifest: ValidatedRecordingManifestEvidence,
        hostTrust: RecordingHostTrustBinding
    ) throws -> StoredVerifiedRecordingReceipt {
        let authenticatedReceipt: HarcAuthenticatedRecordingReceiptV1
        do {
            authenticatedReceipt = try evidenceCodec.authenticateRecordingReceipt(
                exactSignedReceiptBytes: exactBytes,
                validatedManifest: manifest,
                hostTrust: hostTrust
            )
        } catch {
            throw HarcForegroundRecordingOutboxError
                .evidenceValidationFailed(String(reflecting: error))
        }
        // This transaction is the sole transition to committed and the sole
        // source of cleanup eligibility. No file is deleted here.
        return try store.persistVerifiedRecordingReceipt(
            authenticatedReceipt,
            verifiedAt: try flooredWireDate(
                now(),
                field: "receiptVerifiedAt"
            )
        )
    }

    private func receiptFromStatus(
        plan: HarcForegroundRecordingUploadPlan,
        protocolVersion: HarcProtocolVersion,
        rpc: HarcValidatedRecordingTransferRPCClientV1
    ) async throws -> Data? {
        var request = Harc_V1_GetRecordingStatusRequestV1()
        request.protocol = protocolVersion.protobufV1()
        request.uploadID = Harc_V1_UploadIDV1(plan.uploadID)
        let status = try await rpc.getRecordingStatus(request)
        guard status.originRecordingID == plan.originRecordingID else {
            throw HarcForegroundRecordingOutboxError
                .remoteStateMismatch(field: "recordingStatusOrigin")
        }
        return status.recordingReceipt?.exactBytes
    }

    private func beginActiveUploadIfNeeded(origin: OriginRecordingID) throws {
        _ = try store.updateRecordingOutbox(for: origin) { machine in
            if machine.state == .authorizing {
                try machine.beginActiveUpload()
            }
        }
    }

    private func validatePreparedBackgroundBatches(
        _ batches: [HarcPreparedBackgroundAudioBatchV1],
        missingChunks: [HarcForegroundEncodedChunk],
        attempt: UploadAttempt,
        plan: HarcForegroundRecordingUploadPlan
    ) throws {
        guard !batches.isEmpty,
              batches.count <= missingChunks.count,
              Set(batches.map(\.descriptor.batchID)).count == batches.count,
              Set(batches.map { $0.bodyFileURL.path }).count == batches.count,
              batches.flatMap(\.descriptor.chunks)
                == missingChunks.map(\.descriptor) else {
            throw HarcForegroundRecordingOutboxError.invalidPlan(
                field: "backgroundBatches.coverage"
            )
        }
        for batch in batches {
            guard batch.descriptor.uploadID == attempt.uploadID,
                  batch.descriptor.generation == attempt.generation,
                  batch.descriptor.uploadProfileSHA256
                    == attempt.frozenProfile.profileSHA256,
                  batch.descriptor.originRecordingID
                    == attempt.originRecordingID,
                  batch.descriptor.ownerDeviceID == attempt.ownerDeviceID,
                  batch.descriptor.originRecordingID
                    == plan.originRecordingID else {
                throw HarcForegroundRecordingOutboxError.invalidPlan(
                    field: "backgroundBatches.identity"
                )
            }
        }
    }

    private func activeBackgroundTaskIdentities(
        uploadID: UploadID
    ) throws -> [SystemBackgroundTaskIdentity] {
        var identities: [SystemBackgroundTaskIdentity] = []
        for mapping in try store.taskMappings() {
            guard mapping.state == .persistedBeforeResume
                    || mapping.state == .observedBySystem,
                  let batch = try store.backgroundBatch(id: mapping.batchID),
                  batch.descriptor.uploadID == uploadID else { continue }
            identities.append(mapping.identity)
        }
        return identities.sorted {
            $0.taskIdentifier < $1.taskIdentifier
        }
    }

    private func prepareHostCommitPending(origin: OriginRecordingID) throws {
        _ = try store.updateRecordingOutbox(for: origin) { machine in
            if machine.state == .authorizing {
                try machine.beginActiveUpload()
            }
            if machine.state == .activeUpload
                || machine.state == .backgroundScheduled {
                try machine.awaitHostCommit()
            }
        }
    }

    private func requireStoredChunk(
        uploadID: UploadID,
        chunkIndex: UInt32
    ) throws -> StoredUploadChunk {
        guard let chunk = try store.chunks(uploadID: uploadID).first(where: {
            $0.descriptor.chunkIndex == chunkIndex
        }) else {
            throw HarcForegroundRecordingOutboxError
                .invalidPlan(field: "storedChunk")
        }
        return chunk
    }

    private func readAndValidateChunk(
        _ chunk: HarcForegroundEncodedChunk
    ) throws -> Data {
        let descriptor = chunk.descriptor
        guard descriptor.encodedByteLength <= TransferLimits.encodedChunkBytes,
              let expectedCount = Int(exactly: descriptor.encodedByteLength)
        else {
            throw HarcForegroundRecordingOutboxError.localChunkMismatch(
                chunkIndex: descriptor.chunkIndex
            )
        }
        let handle = try FileHandle(forReadingFrom: chunk.encodedFileURL)
        defer { try? handle.close() }
        var bytes = Data()
        bytes.reserveCapacity(expectedCount)
        let boundedLimit = expectedCount + 1
        while bytes.count < boundedLimit {
            let readCount = min(1_048_576, boundedLimit - bytes.count)
            guard let next = try handle.read(upToCount: readCount),
                  !next.isEmpty else {
                break
            }
            bytes.append(next)
        }
        guard bytes.count == expectedCount,
              Data(SHA256.hash(data: bytes))
                == descriptor.encodedSHA256.rawBytes else {
            throw HarcForegroundRecordingOutboxError.localChunkMismatch(
                chunkIndex: descriptor.chunkIndex
            )
        }
        return bytes
    }

    private func blockForSecurityIfPossible(origin: OriginRecordingID) {
        guard let outbox = try? store.recordingOutbox(for: origin) else {
            return
        }
        switch outbox.stateMachine.state {
        case .authorizing, .activeUpload, .backgroundScheduled,
             .hostCommitPending:
            _ = try? store.updateRecordingOutbox(for: origin) {
                try $0.blockForSecurity(.signatureOrObjectMismatch)
            }
        default:
            break
        }
    }

    private func failRecoverablyIfPossible(
        origin: OriginRecordingID,
        error: any Error
    ) {
        guard let outbox = try? store.recordingOutbox(for: origin) else {
            return
        }
        switch outbox.stateMachine.state {
        case .localOnly, .queued, .authorizing, .activeUpload,
             .backgroundScheduled, .hostCommitPending:
            let reflected = String(reflecting: error)
            let boundedDetail = String(reflected.prefix(4_096))
            guard let failure = try? TransferFailure(
                code: "foreground-upload-failed",
                detail: boundedDetail
            ) else { return }
            _ = try? store.updateRecordingOutbox(for: origin) {
                try $0.failRecoverably(failure)
            }
        case .failedRecoverable, .committed, .securityBlocked:
            break
        }
    }

    private func failChunkRecoverablyIfSending(
        uploadID: UploadID,
        chunkIndex: UInt32,
        error: any Error
    ) {
        guard let stored = try? requireStoredChunk(
            uploadID: uploadID,
            chunkIndex: chunkIndex
        ), stored.stateMachine.state == .sending else {
            return
        }
        let reflected = String(reflecting: error)
        let boundedDetail = String(reflected.prefix(4_096))
        guard let failure = try? TransferFailure(
            code: "foreground-chunk-failed",
            detail: boundedDetail
        ) else { return }
        _ = try? store.updateChunkOutbox(
            uploadID: uploadID,
            chunkIndex: chunkIndex
        ) { machine in
            guard machine.state == .sending else { return }
            try machine.failRecoverably(failure, retryFrom: .ready)
        }
    }
}

private extension Array {
    func chunked(maximumCount: Int) -> [[Element]] {
        precondition(maximumCount > 0)
        var result: [[Element]] = []
        result.reserveCapacity((count + maximumCount - 1) / maximumCount)
        var start = 0
        while start < count {
            let end = Swift.min(start + maximumCount, count)
            result.append(Array(self[start ..< end]))
            start = end
        }
        return result
    }
}

private func finalizationReason(
    _ value: CaptureFinalizationReason
) -> Harc_V1_CaptureFinalizationReasonV1 {
    switch value {
    case .userStopped: .captureFinalizationReasonUserStopped
    case .systemEnded: .captureFinalizationReasonSystemEnded
    case .recoveredDurablePrefix:
        .captureFinalizationReasonRecoveredDurablePrefix
    case .storageExhausted: .captureFinalizationReasonStorageExhausted
    case .writerFailure: .captureFinalizationReasonWriterFailure
    }
}

private let foregroundMaximumUnixMilliseconds: UInt64 =
    9_007_199_254_740_991

/// Foundation clocks normally carry sub-millisecond precision, while the wire
/// contract is exact integer milliseconds. Floor once at the boundary and use
/// the resulting Date for every representation of that instant.
private func flooredWireDate(
    _ date: Date,
    field: String
) throws -> Date {
    let seconds = date.timeIntervalSince1970
    let milliseconds = seconds * 1_000
    guard seconds.isFinite, seconds >= 0, milliseconds.isFinite,
          milliseconds <= Double(foregroundMaximumUnixMilliseconds) else {
        throw HarcForegroundRecordingOutboxError.invalidPlan(field: field)
    }
    let floored = milliseconds.rounded(.down)
    guard let exact = UInt64(exactly: floored) else {
        throw HarcForegroundRecordingOutboxError.invalidPlan(field: field)
    }
    return Date(timeIntervalSince1970: Double(exact) / 1_000)
}

private func exactUnixMilliseconds(
    _ date: Date,
    field: String
) throws -> UInt64 {
    let seconds = date.timeIntervalSince1970
    let milliseconds = seconds * 1_000
    guard seconds.isFinite, seconds >= 0, milliseconds.isFinite,
          milliseconds <= Double(foregroundMaximumUnixMilliseconds),
          let result = UInt64(exactly: milliseconds.rounded()),
          Date(timeIntervalSince1970: Double(result) / 1_000) == date else {
        throw HarcForegroundRecordingOutboxError.invalidPlan(field: field)
    }
    return result
}

/// Capture clocks retain their native precision locally. Canonicalize those
/// immutable facts to the wire contract's nearest millisecond when producing
/// begin and signed-manifest evidence. Repeating this operation is stable and
/// also lets durable captures created by older clients resume safely.
private func canonicalUnixMilliseconds(
    _ date: Date,
    field: String
) throws -> UInt64 {
    let seconds = date.timeIntervalSince1970
    let milliseconds = seconds * 1_000
    guard seconds.isFinite, seconds >= 0, milliseconds.isFinite,
          milliseconds <= Double(foregroundMaximumUnixMilliseconds),
          let result = UInt64(exactly: milliseconds.rounded()) else {
        throw HarcForegroundRecordingOutboxError.invalidPlan(field: field)
    }
    return result
}

private func wireCanonicalDate(
    _ date: Date,
    field: String
) throws -> Date {
    Date(
        timeIntervalSince1970: Double(
            try canonicalUnixMilliseconds(date, field: field)
        ) / 1_000
    )
}

/// Manifest validation decodes wire dates at millisecond precision. Compare
/// that evidence with the same deterministic projection of the durable local
/// capture, while leaving the higher-precision local facts untouched.
private func wireCanonicalCapture(
    _ value: ChunkedFinalizedCapture
) throws -> ChunkedFinalizedCapture {
    let capture = value.capture
    let discontinuities = try capture.discontinuities.map { discontinuity in
        try CaptureDiscontinuity(
            recordingID: discontinuity.recordingID,
            monotonicTimeNanoseconds:
                discontinuity.monotonicTimeNanoseconds,
            wallTime: wireCanonicalDate(
                discontinuity.wallTime,
                field: "captureDiscontinuity.wallTime"
            ),
            reason: discontinuity.reason,
            oldRoute: discontinuity.oldRoute,
            newRoute: discontinuity.newRoute,
            affectedFrames: discontinuity.affectedFrames,
            canonicalizationPolicy: discontinuity.canonicalizationPolicy
        )
    }
    let canonical = try FinalizedCapture(
        producingDeviceID: capture.producingDeviceID,
        originRecordingID: capture.originRecordingID,
        captureStartedAt: wireCanonicalDate(
            capture.captureStartedAt,
            field: "manifestCaptureStartedAt"
        ),
        captureEndedAt: wireCanonicalDate(
            capture.captureEndedAt,
            field: "manifestCaptureEndedAt"
        ),
        captureStartedMonotonicNanoseconds:
            capture.captureStartedMonotonicNanoseconds,
        captureEndedMonotonicNanoseconds:
            capture.captureEndedMonotonicNanoseconds,
        finalizationReason: capture.finalizationReason,
        canonicalFormat: capture.canonicalFormat,
        totalCanonicalFrames: capture.totalCanonicalFrames,
        totalCanonicalBytes: capture.totalCanonicalBytes,
        canonicalPCMSHA256: capture.canonicalPCMSHA256,
        discontinuities: discontinuities
    )
    return try ChunkedFinalizedCapture(
        capture: canonical,
        chunks: value.chunks
    )
}
