import CryptoKit
import Foundation
import HarcDomain
import HarcIdentity
import HarcStore
import HarcTransfer

public struct HostCanonicalRecoveryReport: Equatable, Sendable {
    public let attemptedUploadCount: Int
    public let recoveredReceiptCount: Int
    public let failedUploadIDs: [UploadID]

    public init(
        attemptedUploadCount: Int,
        recoveredReceiptCount: Int,
        failedUploadIDs: [UploadID]
    ) {
        self.attemptedUploadCount = attemptedUploadCount
        self.recoveredReceiptCount = recoveredReceiptCount
        self.failedUploadIDs = failedUploadIDs
    }
}

/// Synchronous claim/release primitive held inside the ingest actor. Claiming
/// occurs before its first suspension so actor reentrancy cannot start a second
/// filesystem saga for the same upload.
struct HostPublicationActivityGate {
    private var activeUploadIDs: Set<UploadID> = []

    mutating func claim(_ uploadID: UploadID) throws {
        guard activeUploadIDs.insert(uploadID).inserted else {
            throw HarcHostError.canonicalPublicationAlreadyInProgress(uploadID)
        }
    }

    mutating func release(_ uploadID: UploadID) {
        activeUploadIDs.remove(uploadID)
    }
}

/// Transport-neutral canonical ingest application service. The actor is the
/// serialization point for publication inside one resident Host process; its
/// restart journal and HarcStore origin identity remain the authority across
/// process death.
public actor HarcCanonicalIngestService {
    private static let maximumStreamingFragmentBytes = 256 * 1_024

    private let hostStore: HarcHostStore
    private let recordingStore: RecordingStore
    private let canonicalCommitCapability: HostCanonicalCommitCapability
    private let canonicalRootAnchor: HostCanonicalRootAnchor
    private let decoder: any HostChunkDecoding
    private let manifestValidator: any RecordingManifestEvidenceValidating
    private let hostTrust: RecordingHostTrustBinding
    private let receiptIssuer: any RecordingReceiptIssuing
    private let receiptValidator: any RecordingReceiptEvidenceValidating
    private let hostAuthoritySigner: any P256DigestSigner
    private let processingScheduler: any HostReceiptDurableProcessingScheduling
    private let failureInjector: any HostPublicationFailureInjector
    private let now: @Sendable () -> Date
    private var activityGate = HostPublicationActivityGate()

    public init(
        hostStore: HarcHostStore,
        recordingStore: RecordingStore,
        canonicalCommitCapability: HostCanonicalCommitCapability,
        canonicalRoot: URL,
        decoder: any HostChunkDecoding = QualifiedHostChunkDecoderUnavailable(),
        manifestValidator: any RecordingManifestEvidenceValidating,
        receiptIssuer: any RecordingReceiptIssuing,
        receiptValidator: any RecordingReceiptEvidenceValidating,
        hostAuthoritySigner: any P256DigestSigner,
        processingScheduler: any HostReceiptDurableProcessingScheduling = UnavailableHostProcessingScheduler(),
        failureInjector: any HostPublicationFailureInjector = NoHostPublicationFailureInjector(),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard canonicalRoot.isFileURL,
              canonicalRoot.standardizedFileURL.path == canonicalRoot.path,
              hostAuthoritySigner.publicKey.hostAuthorityID
                == hostStore.expectedMetadata.hostAuthorityID,
              hostStore.expectedMetadata.libraryID
                == canonicalCommitCapability.identity.libraryID,
              hostStore.expectedMetadata.hostAuthorityID
                == canonicalCommitCapability.identity.hostAuthorityID,
              hostStore.expectedMetadata.hostStateID
                == canonicalCommitCapability.identity.hostStateID
        else {
            throw HarcHostError.metadataMismatch
        }
        self.hostStore = hostStore
        self.recordingStore = recordingStore
        self.canonicalCommitCapability = canonicalCommitCapability
        canonicalRootAnchor = try HostCanonicalRootAnchor(root: canonicalRoot)
        self.decoder = decoder
        self.manifestValidator = manifestValidator
        self.hostTrust = try RecordingHostTrustBinding(
            libraryID: hostStore.expectedMetadata.libraryID,
            hostAuthorityID: hostStore.expectedMetadata.hostAuthorityID,
            hostAuthorityPublicKey: hostAuthoritySigner.publicKey
        )
        self.receiptIssuer = receiptIssuer
        self.receiptValidator = receiptValidator
        self.hostAuthoritySigner = hostAuthoritySigner
        self.processingScheduler = processingScheduler
        self.failureInjector = failureInjector
        self.now = now
    }

    /// Authenticates and binds a device-signed final manifest using the same
    /// validator and authority identity that canonical publication will later
    /// use. Key lookup and binding remain atomic inside HarcHostStore.
    public func validateAndBindFinalManifestForPrecommit(
        context: AuthenticatedDeviceContext,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256,
        exactSignedManifestBytes: Data
    ) async throws -> HostManifestPrecommitDisposition {
        try await hostStore.validateAndBindFinalManifestForPrecommit(
            context: context,
            uploadID: uploadID,
            generation: generation,
            expectedUploadProfileSHA256: expectedUploadProfileSHA256,
            exactSignedManifestBytes: exactSignedManifestBytes,
            hostTrust: hostTrust,
            validator: manifestValidator
        )
    }

    /// Starts or resumes one already-manifest-bound upload. Current device and
    /// grant authorization occurs only while the immutable publication plan is
    /// first accepted. Later crash recovery uses that durable acceptance fact.
    public func beginUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        request: BeginHostUploadRequest
    ) async throws -> BeginHostUploadDisposition {
        let disposition = try await hostStore.beginUpload(
            context: context,
            sessionCapabilities: sessionCapabilities,
            request: request
        )
        guard case .alreadyCommitted(let receipt) = disposition else {
            return disposition
        }
        guard let processing = try await hostStore.receiptProcessingWork(
            originRecordingID: request.originRecordingID,
            expectedReceipt: receipt
        ) else {
            throw HarcHostError.databaseFailure(
                "A committed origin has no canonical artifact evidence."
            )
        }
        return .alreadyCommitted(
            try await deliverReceipt(
                processing,
                expectedReceipt: receipt,
                handoff: .asynchronous
            )
        )
    }

    /// Returns the client's durable upload state. A committed reconciliation
    /// is a cleanup-authorizing receipt replay, so it is exposed only after the
    /// journaled canonical WAV has been reopened through the retained root and
    /// revalidated against its persisted artifact identity and PCM claims.
    public func reconcileUpload(
        for uploadID: UploadID,
        expectedUploadProfileSHA256: UploadProfileSHA256,
        context: AuthenticatedDeviceContext
    ) async throws -> UploadReconciliation {
        let reconciliation = try await hostStore.reconciliation(
            for: uploadID,
            expectedUploadProfileSHA256: expectedUploadProfileSHA256,
            context: context
        )
        guard let receipt = reconciliation.existingReceipt else {
            return reconciliation
        }
        guard reconciliation.terminalReason == .committed,
              let processing = try await hostStore.receiptProcessingWork(
                  uploadID: uploadID
              ),
              processing.exactReceipt == receipt
        else {
            throw HarcHostError.databaseFailure(
                "A committed reconciliation has no exact canonical artifact evidence."
            )
        }
        try validateReceiptedArtifact(processing)
        return reconciliation
    }

    public func commitUpload(
        context: AuthenticatedDeviceContext,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256
    ) async throws -> OpaqueExactObjectSlot {
        try await commitUploadWithDisposition(
            context: context,
            uploadID: uploadID,
            generation: generation,
            expectedUploadProfileSHA256: expectedUploadProfileSHA256
        ).exactReceipt
    }

    /// Commits one upload while preserving whether this invocation drove the
    /// first successful publication or replayed an already durable receipt.
    /// A recovered in-progress publication is still the first commit response;
    /// only a receipt present at admission is an exact replay.
    public func commitUploadWithDisposition(
        context: AuthenticatedDeviceContext,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256
    ) async throws -> HostCanonicalCommitDisposition {
        try activityGate.claim(uploadID)
        defer { activityGate.release(uploadID) }
        let preparation = try await hostStore.prepareCanonicalPublication(
            context: context,
            uploadID: uploadID,
            generation: generation,
            expectedUploadProfileSHA256: expectedUploadProfileSHA256
        )
        let receipt = try await drive(
            preparation,
            uploadID: uploadID,
            processingHandoff: .asynchronous
        )
        switch preparation {
        case .alreadyReceipted:
            return .exactReplay(receipt)
        case .work:
            return .committed(receipt)
        }
    }

    /// Completes one plan without a live client or current grant. This is the
    /// focused primitive used by startup recovery and kill-point tests.
    public func recoverPublication(uploadID: UploadID) async throws -> OpaqueExactObjectSlot {
        try activityGate.claim(uploadID)
        defer { activityGate.release(uploadID) }
        if let processing = try await hostStore.receiptProcessingWork(uploadID: uploadID) {
            return try await deliverReceipt(
                processing,
                expectedReceipt: processing.exactReceipt,
                handoff: .bestEffortSynchronous
            )
        }
        let preparation = try await hostStore.canonicalPublicationForRecovery(
            uploadID: uploadID
        )
        return try await drive(
            preparation,
            uploadID: uploadID,
            processingHandoff: .bestEffortSynchronous
        )
    }

    /// Best-effort startup scan. One corrupt or externally blocked publication
    /// cannot prevent independent accepted recordings from recovering.
    public func recoverPendingPublications() async throws -> HostCanonicalRecoveryReport {
        let uploadIDs = try await hostStore.recoverableCanonicalPublicationIDs()
        var recoveredReceiptCount = 0
        var failed: [UploadID] = []
        failed.reserveCapacity(uploadIDs.count)
        for uploadID in uploadIDs {
            do {
                _ = try await recoverPublication(uploadID: uploadID)
                recoveredReceiptCount += 1
            } catch {
                failed.append(uploadID)
            }
        }
        return HostCanonicalRecoveryReport(
            attemptedUploadCount: uploadIDs.count,
            recoveredReceiptCount: recoveredReceiptCount,
            failedUploadIDs: failed
        )
    }
}

private extension HarcCanonicalIngestService {
    enum ProcessingHandoff {
        case asynchronous
        case bestEffortSynchronous
    }

    func drive(
        _ initialPreparation: HostCanonicalPublicationPreparation,
        uploadID: UploadID,
        processingHandoff: ProcessingHandoff
    ) async throws -> OpaqueExactObjectSlot {
        if case .alreadyReceipted(let receipt) = initialPreparation {
            guard let processing = try await hostStore.receiptProcessingWork(
                uploadID: uploadID
            ) else {
                throw HarcHostError.databaseFailure(
                    "A committed upload has no canonical artifact evidence."
                )
            }
            return try await deliverReceipt(
                processing,
                expectedReceipt: receipt,
                handoff: processingHandoff
            )
        }

        do {
            try await failureInjector.hit(.afterPublicationPlan)
            var preparation = initialPreparation
            while true {
                switch preparation {
                case .alreadyReceipted(let receipt):
                    guard let processing = try await hostStore.receiptProcessingWork(
                        uploadID: uploadID
                    ) else {
                        throw HarcHostError.databaseFailure(
                            "A committed upload has no canonical artifact evidence."
                        )
                    }
                    return try await deliverReceipt(
                        processing,
                        expectedReceipt: receipt,
                        handoff: processingHandoff
                    )

                case .work(let work):
                    switch work.checkpoint {
                    case .assembling:
                        try await assembleCanonicalWAV(work)
                    case .temporarySynchronized:
                        try await publishCanonicalWAV(work)
                    case .audioRenamed:
                        try await synchronizePublishedCanonicalWAV(work)
                    case .audioPublished:
                        try await commitCanonicalRecording(work)
                    case .recordingCommitted:
                        try await prepareExactReceipt(work)
                    case .receiptPrepared:
                        let receipt = try await publishSidecarsAndFinalizeReceipt(work)
                        try await failureInjector.hit(.afterReceiptedCommit)
                        guard let processing = try await hostStore.receiptProcessingWork(
                            uploadID: uploadID
                        ) else {
                            throw HarcHostError.databaseFailure(
                                "A finalized receipt has no canonical artifact evidence."
                            )
                        }
                        return try await deliverReceipt(
                            processing,
                            expectedReceipt: receipt,
                            handoff: processingHandoff
                        )
                    case .receipted, .processing, .complete:
                        guard let processing = try await hostStore.receiptProcessingWork(
                            uploadID: uploadID
                        ) else {
                            throw HarcHostError.databaseFailure(
                                "A receipted publication has no processing work."
                            )
                        }
                        return try await deliverReceipt(
                            processing,
                            expectedReceipt: processing.exactReceipt,
                            handoff: processingHandoff
                        )
                    case .receiving, .manifestVerified, .failedRecoverable,
                         .conflictBlocked, .abandoned:
                        throw HarcHostError.databaseFailure(
                            "Invalid canonical publication checkpoint: \(work.checkpoint.rawValue)."
                        )
                    }
                    preparation = try await hostStore.canonicalPublicationForRecovery(
                        uploadID: uploadID
                    )
                }
            }
        } catch {
            try? await hostStore.markPublicationFailedRecoverable(
                uploadID: uploadID,
                errorCode: "canonical-ingest-failed",
                at: now()
            )
            throw error
        }
    }

    func assembleCanonicalWAV(_ work: HostCanonicalPublicationWork) async throws {
        let paths = try publicationPaths(for: work)
        guard try !paths.entryExists(at: paths.wavURL) else {
            throw HarcHostError.canonicalDestinationExists
        }
        try paths.removeOwnedRegularFileIfPresent(at: paths.temporaryURL)
        try paths.synchronizeDirectory()

        let assembler = try HostCanonicalWAVAssembler(
            paths: paths,
            totalFrames: work.capture.capture.totalCanonicalFrames
        )
        try await failureInjector.hit(.afterTemporaryFileCreation)

        for staged in work.stagedChunks {
            let sink = HostDecodedChunkSink(
                descriptor: staged.descriptor,
                assembler: assembler,
                maximumFragmentBytes: Self.maximumStreamingFragmentBytes
            )
            try await decodeAndVerify(
                staged,
                uploadPurpose: work.attempt.frozenProfile.purpose,
                into: sink
            )
        }

        try await failureInjector.hit(.afterCanonicalAssembly)
        _ = try assembler.synchronizeAndClose(
            expectedPCMHash: work.capture.capture.canonicalPCMSHA256
        )
        // File fsync makes the bytes durable; directory fsync makes the newly
        // created sibling temp name durable before HostDB may record it.
        try HostCanonicalWAVAssembler.synchronizeDirectory(paths)
        try await failureInjector.hit(.afterTemporaryFileSynchronization)
        try await hostStore.markPublicationCheckpoint(
            uploadID: work.attempt.uploadID,
            expected: [.assembling],
            next: .temporarySynchronized,
            at: now()
        )
    }

    func publishCanonicalWAV(_ work: HostCanonicalPublicationWork) async throws {
        let paths = try publicationPaths(for: work)
        let temporaryExists = try paths.entryExists(at: paths.temporaryURL)
        let finalExists = try paths.entryExists(at: paths.wavURL)
        if temporaryExists {
            guard !finalExists else { throw HarcHostError.canonicalDestinationExists }
            try HostCanonicalWAVAssembler.validatePublishedFile(
                at: paths.temporaryURL,
                in: paths,
                totalFrames: work.capture.capture.totalCanonicalFrames,
                expectedPCMHash: work.capture.capture.canonicalPCMSHA256
            )
            try HostCanonicalWAVAssembler.publishExclusively(in: paths)
        } else {
            // A process may die after rename but before the HostDB checkpoint.
            guard finalExists else {
                throw HarcHostError.publicationIO(
                    "The synchronized canonical temporary file is missing."
                )
            }
            try HostCanonicalWAVAssembler.validatePublishedFile(
                at: paths.wavURL,
                in: paths,
                totalFrames: work.capture.capture.totalCanonicalFrames,
                expectedPCMHash: work.capture.capture.canonicalPCMSHA256
            )
        }
        try await failureInjector.hit(.afterAudioRename)
        // Do not advance the HostDB journal until the rename is durable. If a
        // process dies at the seam above, `.temporarySynchronized` recovery can
        // accept the final name or redo the rename from the durable temp name.
        try HostCanonicalWAVAssembler.synchronizeDirectory(paths)
        try await hostStore.markPublicationCheckpoint(
            uploadID: work.attempt.uploadID,
            expected: [.temporarySynchronized],
            next: .audioRenamed,
            at: now()
        )
    }

    func synchronizePublishedCanonicalWAV(
        _ work: HostCanonicalPublicationWork
    ) async throws {
        let paths = try publicationPaths(for: work)
        let artifact = try HostCanonicalWAVAssembler.openValidatedPublishedFile(
            at: paths.wavURL,
            in: paths,
            totalFrames: work.capture.capture.totalCanonicalFrames,
            expectedPCMHash: work.capture.capture.canonicalPCMSHA256
        )
        try HostCanonicalWAVAssembler.synchronizeDirectory(paths)
        // Keep the identity captured before the hash bound to the same name
        // after directory durability and immediately before HostDB acquires it.
        try artifact.validateBinding()
        try await failureInjector.hit(.afterAudioDirectorySynchronization)
        try artifact.validateBinding()
        try await hostStore.persistPublishedCanonicalArtifact(
            uploadID: work.attempt.uploadID,
            identity: artifact.identity,
            at: now()
        )
    }

    func commitCanonicalRecording(_ work: HostCanonicalPublicationWork) async throws {
        let paths = try publicationPaths(for: work)
        let artifact = try validatedCanonicalArtifact(for: work, paths: paths)
        let capture = work.capture.capture
        let request = try HostCanonicalRecordingCommitRequest(
            canonicalID: work.canonicalRecordingID,
            originID: capture.originRecordingID,
            canonicalPCMHash: capture.canonicalPCMSHA256,
            canonicalPCMFrames: capture.totalCanonicalFrames,
            canonicalWAVURL: paths.wavURL,
            artifactIdentity: artifact.identity,
            startedAt: capture.captureStartedAt,
            endedAt: capture.captureEndedAt
        )
        try artifact.validateBinding()
        let result = try await recordingStore.commitCanonicalRemoteRecording(
            request,
            using: canonicalCommitCapability
        )
        // The descriptor remains alive across the store transaction; prove the
        // committed name and bytes still match before HostDB links evidence.
        try artifact.validateCanonicalContent()
        try await failureInjector.hit(.afterCanonicalDatabaseCommit)
        try artifact.validateBinding()
        try await hostStore.persistCanonicalCommitLinkage(
            uploadID: work.attempt.uploadID,
            canonicalRecordingID: work.canonicalRecordingID,
            publicationRelativePath: work.publicationRelativePath,
            artifactIdentity: artifact.identity,
            result: result,
            at: now()
        )
        try artifact.validateBinding()
        try await failureInjector.hit(.afterHostPublicationLinkage)
    }

    func prepareExactReceipt(_ work: HostCanonicalPublicationWork) async throws {
        guard let revision = work.canonicalRevision,
              let cursor = work.changeCursor,
              let durableCommitTime = work.durableCommitTime,
              work.exactPersistedReceipt == nil
        else {
            throw HarcHostError.databaseFailure(
                "Canonical commit evidence is incomplete before receipt issuance."
            )
        }
        let paths = try publicationPaths(for: work)
        let artifact = try validatedCanonicalArtifact(for: work, paths: paths)
        let manifest = try await hostStore.validateBoundManifest(
            uploadID: work.attempt.uploadID,
            using: manifestValidator
        )
        try artifact.validateBinding()
        let receiptID = work.receiptID ?? UUID()
        let claims = try RecordingReceiptClaims(
            validatedManifest: manifest,
            canonicalRecordingID: work.canonicalRecordingID,
            canonicalRevision: revision,
            changeCursor: cursor,
            receiptID: receiptID,
            durableCommitTime: durableCommitTime
        )
        let exactReceipt = try receiptIssuer.issueRecordingReceipt(
            claims: claims,
            hostAuthoritySigner: hostAuthoritySigner
        )
        try artifact.validateBinding()
        try await failureInjector.hit(.afterReceiptCreation)
        let evidence = try receiptValidator.validateRecordingReceipt(
            exactSignedReceiptBytes: exactReceipt.exactBytes,
            validatedManifest: manifest,
            hostTrust: manifest.hostTrust
        )
        guard evidence.exactReceiptObject == exactReceipt,
              evidence.canonicalRecordingID == work.canonicalRecordingID,
              evidence.canonicalRevision == revision,
              evidence.changeCursor == cursor,
              evidence.receiptID == receiptID,
              evidence.durableCommitTime == durableCommitTime,
              evidence.processingState == .pending
        else {
            throw HarcHostError.databaseFailure("Issued receipt claims failed exact validation.")
        }
        try artifact.validateBinding()
        try await hostStore.persistPreparedPublicationReceipt(
            uploadID: work.attempt.uploadID,
            receiptID: receiptID,
            exactReceipt: exactReceipt,
            evidence: evidence,
            at: now()
        )
        try artifact.validateBinding()
        try await failureInjector.hit(.afterReceiptPersistence)
    }

    func publishSidecarsAndFinalizeReceipt(
        _ work: HostCanonicalPublicationWork
    ) async throws -> OpaqueExactObjectSlot {
        guard let manifestObject = work.attempt.boundManifest,
              let exactReceipt = work.exactPersistedReceipt,
              let receiptID = work.receiptID,
              let revision = work.canonicalRevision,
              let cursor = work.changeCursor,
              let durableCommitTime = work.durableCommitTime
        else {
            throw HarcHostError.databaseFailure("Prepared receipt journal is incomplete.")
        }
        let paths = try publicationPaths(for: work)
        let artifact = try validatedCanonicalArtifact(for: work, paths: paths)
        let manifest = try await hostStore.validateBoundManifest(
            uploadID: work.attempt.uploadID,
            using: manifestValidator
        )
        try artifact.validateBinding()
        let evidence = try receiptValidator.validateRecordingReceipt(
            exactSignedReceiptBytes: exactReceipt.exactBytes,
            validatedManifest: manifest,
            hostTrust: manifest.hostTrust
        )
        guard evidence.exactReceiptObject == exactReceipt,
              evidence.receiptID == receiptID,
              evidence.canonicalRecordingID == work.canonicalRecordingID,
              evidence.canonicalRevision == revision,
              evidence.changeCursor == cursor,
              evidence.durableCommitTime == durableCommitTime,
              evidence.processingState == .pending
        else {
            throw HarcHostError.databaseFailure("Persisted receipt claims drifted.")
        }

        // No provenance entry is created until the exact journaled WAV has
        // been re-opened through the retained root and fully revalidated.
        try artifact.validateBinding()
        try HostCanonicalWAVAssembler.writeExactSidecar(
            manifestObject.exactBytes,
            to: paths.manifestSidecarURL,
            in: paths
        )
        try artifact.validateBinding()
        try await failureInjector.hit(.afterManifestSidecarPublication)
        try await hostStore.markPublicationSidecarSynchronized(
            uploadID: work.attempt.uploadID,
            kind: .manifest,
            at: now()
        )

        try artifact.validateBinding()
        try HostCanonicalWAVAssembler.writeExactSidecar(
            exactReceipt.exactBytes,
            to: paths.receiptSidecarURL,
            in: paths
        )
        try artifact.validateBinding()
        try await failureInjector.hit(.afterReceiptSidecarPublication)
        try await hostStore.markPublicationSidecarSynchronized(
            uploadID: work.attempt.uploadID,
            kind: .receipt,
            at: now()
        )
        try HostCanonicalWAVAssembler.synchronizeDirectory(paths)
        try artifact.validateBinding()
        try await failureInjector.hit(.afterReceiptDirectorySynchronization)
        try artifact.validateCanonicalContent()
        try await hostStore.finalizePreparedPublicationReceipt(
            uploadID: work.attempt.uploadID,
            evidence: evidence,
            at: now()
        )
        try artifact.validateBinding()
        return exactReceipt
    }

    func deliverReceipt(
        _ work: HostReceiptProcessingWork,
        expectedReceipt: OpaqueExactObjectSlot,
        handoff: ProcessingHandoff
    ) async throws -> OpaqueExactObjectSlot {
        guard work.exactReceipt == expectedReceipt else {
            throw HarcHostError.databaseFailure(
                "The committed upload receipt drifted from its publication journal."
            )
        }
        await scheduleProcessingIfNeeded(work, handoff: handoff)
        // Covers asynchronous failure seams and lost-response replay: a newly
        // delivered receipt is never returned from a replaced/missing WAV.
        try validateReceiptedArtifact(work)
        return expectedReceipt
    }

    func validateReceiptedArtifact(_ work: HostReceiptProcessingWork) throws {
        let paths = try HostCanonicalPublicationPaths.make(
            rootAnchor: canonicalRootAnchor,
            canonicalRecordingID: work.canonicalRecordingID,
            persistedRelativeWAVPath: work.publicationRelativePath,
            temporaryName: work.temporaryName
        )
        _ = try validatedCanonicalArtifact(for: work, paths: paths)
    }

    func scheduleProcessingIfNeeded(
        _ work: HostReceiptProcessingWork,
        handoff: ProcessingHandoff
    ) async {
        guard work.state == .receipted else { return }
        switch handoff {
        case .asynchronous:
            Task { [weak self] in
                guard let self else { return }
                try? await self.scheduleProcessingDurably(work)
            }
        case .bestEffortSynchronous:
            try? await scheduleProcessingDurably(work)
        }
    }

    func scheduleProcessingDurably(_ work: HostReceiptProcessingWork) async throws {
        try await failureInjector.hit(.beforeProcessingSchedule)
        let paths = try HostCanonicalPublicationPaths.make(
            rootAnchor: canonicalRootAnchor,
            canonicalRecordingID: work.canonicalRecordingID,
            persistedRelativeWAVPath: work.publicationRelativePath,
            temporaryName: work.temporaryName
        )
        let artifact = try validatedCanonicalArtifact(for: work, paths: paths)
        let request = try HostDurableProcessingRequest(
            canonicalRecordingID: work.canonicalRecordingID,
            canonicalWAVURL: paths.wavURL,
            canonicalPCMHash: work.canonicalPCMHash,
            canonicalPCMFrames: work.canonicalPCMFrames,
            artifactIdentity: work.canonicalArtifactIdentity
        )
        // This is deliberately adjacent to the handoff. The scheduler receives
        // the same durable claims and must revalidate them before daemon read.
        try artifact.validateBinding()
        try await processingScheduler.schedule(request)
        try await failureInjector.hit(.afterProcessingScheduleBeforeCheckpoint)
        try await hostStore.markPublicationProcessingScheduled(
            uploadID: work.uploadID,
            at: now()
        )
    }

    func validatedCanonicalArtifact(
        for work: HostCanonicalPublicationWork,
        paths: HostCanonicalPublicationPaths
    ) throws -> HostValidatedCanonicalArtifact {
        guard let expectedIdentity = work.canonicalArtifactIdentity else {
            throw HarcHostError.publicationRecoveryRequired(
                "published canonical artifact identity is missing"
            )
        }
        return try HostCanonicalWAVAssembler.openValidatedPublishedFile(
            at: paths.wavURL,
            in: paths,
            totalFrames: work.capture.capture.totalCanonicalFrames,
            expectedPCMHash: work.capture.capture.canonicalPCMSHA256,
            expectedIdentity: expectedIdentity
        )
    }

    func validatedCanonicalArtifact(
        for work: HostReceiptProcessingWork,
        paths: HostCanonicalPublicationPaths
    ) throws -> HostValidatedCanonicalArtifact {
        try HostCanonicalWAVAssembler.openValidatedPublishedFile(
            at: paths.wavURL,
            in: paths,
            totalFrames: work.canonicalPCMFrames,
            expectedPCMHash: work.canonicalPCMHash,
            expectedIdentity: work.canonicalArtifactIdentity
        )
    }

    func publicationPaths(
        for work: HostCanonicalPublicationWork
    ) throws -> HostCanonicalPublicationPaths {
        let paths = try HostCanonicalPublicationPaths.make(
            rootAnchor: canonicalRootAnchor,
            canonicalRecordingID: work.canonicalRecordingID,
            persistedRelativeWAVPath: work.publicationRelativePath,
            temporaryName: work.temporaryName
        )
        return paths
    }

    func decodeAndVerify(
        _ staged: HostDurableStagedChunk,
        uploadPurpose: UploadProfilePurpose,
        into sink: HostDecodedChunkSink
    ) async throws {
        // Each phase gets an independently opened descriptor at offset zero.
        // No pathname is handed to a decoder, and no mutable file position is
        // shared between the authoritative prehash, decode, and posthash.
        do {
            let prehashHandle = try hostStore.openDurableStagedObject(staged)
            defer { prehashHandle.close() }
            try prehashHandle.verifyEncodedObject(
                matches: staged.descriptor,
                maximumFragmentBytes: Self.maximumStreamingFragmentBytes
            )
        }

        do {
            let decodeHandle = try hostStore.openDurableStagedObject(staged)
            defer { decodeHandle.close() }
            try await decoder.decode(
                HostChunkDecodeRequest(
                    stagedEncodedHandle: decodeHandle,
                    descriptor: staged.descriptor,
                    uploadPurpose: uploadPurpose
                )
            ) { fragment in
                try await sink.append(fragment)
            }
        }

        do {
            let posthashHandle = try hostStore.openDurableStagedObject(staged)
            defer { posthashHandle.close() }
            try posthashHandle.verifyEncodedObject(
                matches: staged.descriptor,
                maximumFragmentBytes: Self.maximumStreamingFragmentBytes
            )
        }
        try await sink.finish()
    }

}

private actor HostDecodedChunkSink {
    private let descriptor: LogicalChunkDescriptor
    private let assembler: HostCanonicalWAVAssembler
    private let maximumFragmentBytes: Int
    private var hasher = SHA256()
    private var bytesReceived: UInt64 = 0
    private var finished = false

    init(
        descriptor: LogicalChunkDescriptor,
        assembler: HostCanonicalWAVAssembler,
        maximumFragmentBytes: Int
    ) {
        self.descriptor = descriptor
        self.assembler = assembler
        self.maximumFragmentBytes = maximumFragmentBytes
    }

    func append(_ fragment: Data) throws {
        guard !finished else {
            throw HarcHostError.publicationIO("A decoder emitted bytes after completion.")
        }
        guard !fragment.isEmpty else {
            throw HarcHostError.publicationIO("A decoder emitted an empty PCM fragment.")
        }
        guard fragment.count <= maximumFragmentBytes else {
            throw HarcHostError.bodyFragmentTooLarge(
                limit: maximumFragmentBytes,
                actual: fragment.count
            )
        }
        let total = bytesReceived.addingReportingOverflow(UInt64(fragment.count))
        guard !total.overflow,
              total.partialValue <= descriptor.canonicalDecodedByteLength
        else {
            throw HarcHostError.decodedLengthMismatch(
                expected: descriptor.canonicalDecodedByteLength,
                actual: total.partialValue
            )
        }
        try assembler.appendCanonicalPCM(fragment)
        hasher.update(data: fragment)
        bytesReceived = total.partialValue
    }

    func finish() throws {
        guard !finished else {
            throw HarcHostError.publicationIO("A decoder completed one chunk more than once.")
        }
        finished = true
        guard bytesReceived == descriptor.canonicalDecodedByteLength else {
            throw HarcHostError.decodedLengthMismatch(
                expected: descriptor.canonicalDecodedByteLength,
                actual: bytesReceived
            )
        }
        guard Data(hasher.finalize()) == descriptor.canonicalDecodedSHA256.rawBytes else {
            throw HarcHostError.canonicalHashMismatch
        }
    }
}
