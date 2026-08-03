import CryptoKit
import Darwin
import Foundation
import GRDB
import HarcDomain
import HarcIdentity
@testable import HarcStore
import HarcTransfer
import Testing
@testable import HarcHost

private enum InjectedPublicationCrash: Error, Equatable {
    case point(HostPublicationFailurePoint)
}

private actor OneShotPublicationFailureInjector: HostPublicationFailureInjector {
    private var target: HostPublicationFailurePoint?
    private var triggered = false

    init(_ target: HostPublicationFailurePoint?) {
        self.target = target
    }

    func hit(_ point: HostPublicationFailurePoint) throws {
        guard target == point else { return }
        target = nil
        triggered = true
        throw InjectedPublicationCrash.point(point)
    }

    func wasTriggered() -> Bool { triggered }
}

private actor IdempotentProcessingScheduler: HostReceiptDurableProcessingScheduling {
    private var attempts = 0
    private var enqueued: Set<CanonicalRecordingID> = []

    func schedule(_ request: HostDurableProcessingRequest) throws {
        try request.artifactIdentity.validatePathBinding(at: request.canonicalWAVURL)
        attempts += 1
        enqueued.insert(request.canonicalRecordingID)
    }

    func snapshot() -> (attempts: Int, unique: Int) {
        (attempts, enqueued.count)
    }
}

private actor FailingProcessingScheduler: HostReceiptDurableProcessingScheduling {
    private var attempts = 0

    func schedule(_ request: HostDurableProcessingRequest) throws {
        attempts += 1
        throw HarcHostError.processingSchedulerUnavailable
    }

    func attemptCount() -> Int { attempts }
}

/// Test-only deterministic stand-in for the PR4 protobuf codec. Protocol
/// signature and equality behavior has its own golden/negative suite; these
/// tests exercise HarcHost's durable orchestration through the same Transfer
/// seams without making HarcHost depend on HarcProtocol.
private struct LoopbackRecordingEvidenceCodec: Sendable,
    RecordingManifestEvidenceValidating,
    RecordingReceiptIssuing,
    RecordingReceiptEvidenceValidating
{
    private struct ReceiptPayload: Codable {
        let canonicalRecordingID: UUID
        let revision: UInt64
        let changeCursor: UInt64
        let receiptID: UUID
        let durableCommitUnixMilliseconds: UInt64
    }

    let manifest: ValidatedRecordingManifestEvidence

    func validateRecordingManifest(
        exactSignedManifestBytes: Data,
        hostTrust: RecordingHostTrustBinding,
        producingDevicePublicKey: P256X963PublicKey
    ) throws -> ValidatedRecordingManifestEvidence {
        guard exactSignedManifestBytes == manifest.exactManifestObject.exactBytes,
              hostTrust == manifest.hostTrust,
              producingDevicePublicKey == manifest.producingDevicePublicKey
        else { throw HarcHostError.manifestEvidenceRequired }
        return manifest
    }

    func issueRecordingReceipt(
        claims: RecordingReceiptClaims,
        hostAuthoritySigner: any P256DigestSigner
    ) throws -> OpaqueExactObjectSlot {
        guard claims.validatedManifest == manifest,
              hostAuthoritySigner.publicKey == manifest.hostTrust.hostAuthorityPublicKey
        else { throw HarcHostError.manifestEvidenceRequired }
        let milliseconds = claims.durableCommitTime.timeIntervalSince1970 * 1_000
        guard let exactMilliseconds = UInt64(exactly: milliseconds.rounded()),
              Date(timeIntervalSince1970: Double(exactMilliseconds) / 1_000)
                == claims.durableCommitTime
        else { throw HarcHostError.databaseFailure("Test receipt time is not exact.") }
        let payload = ReceiptPayload(
            canonicalRecordingID: claims.canonicalRecordingID.rawValue,
            revision: claims.canonicalRevision.rawValue,
            changeCursor: claims.changeCursor.rawValue,
            receiptID: claims.receiptID,
            durableCommitUnixMilliseconds: exactMilliseconds
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let exactBytes = try encoder.encode(payload)
        return try OpaqueExactObjectSlot(
            kind: .recordingReceiptV1,
            exactBytes: exactBytes,
            objectSHA256: ExactObjectSHA256(Data(SHA256.hash(data: exactBytes)))
        )
    }

    func validateRecordingReceipt(
        exactSignedReceiptBytes: Data,
        validatedManifest: ValidatedRecordingManifestEvidence,
        hostTrust: RecordingHostTrustBinding
    ) throws -> ValidatedRecordingReceiptEvidence {
        guard validatedManifest == manifest, hostTrust == manifest.hostTrust else {
            throw HarcHostError.manifestEvidenceRequired
        }
        let payload = try JSONDecoder().decode(
            ReceiptPayload.self,
            from: exactSignedReceiptBytes
        )
        let exactObject = try OpaqueExactObjectSlot(
            kind: .recordingReceiptV1,
            exactBytes: exactSignedReceiptBytes,
            objectSHA256: ExactObjectSHA256(
                Data(SHA256.hash(data: exactSignedReceiptBytes))
            )
        )
        return try ValidatedRecordingReceiptEvidence(
            hostTrust: hostTrust,
            exactReceiptObject: exactObject,
            validatedManifest: validatedManifest,
            uploadID: manifest.uploadID,
            originRecordingID: manifest.originRecordingID,
            signedManifestObjectSHA256: manifest.exactManifestObject.objectSHA256,
            canonicalPCMSHA256: manifest.canonicalPCMSHA256,
            totalCanonicalFrames: manifest.totalCanonicalFrames,
            canonicalFormat: manifest.canonicalFormat,
            canonicalRecordingID: CanonicalRecordingID(payload.canonicalRecordingID),
            canonicalRevision: EntityRevision(payload.revision),
            changeCursor: ChangeCursor(payload.changeCursor),
            receiptID: payload.receiptID,
            durableCommitTime: Date(
                timeIntervalSince1970:
                    Double(payload.durableCommitUnixMilliseconds) / 1_000
            ),
            processingState: .pending
        )
    }
}

private struct PreparedCanonicalIngest {
    let root: URL
    let harcDatabaseURL: URL
    let hostDatabaseURL: URL
    let stagingRoot: URL
    let canonicalRoot: URL
    let metadata: HarcHostMetadata
    let highWaterMarkStore: InMemorySecurityRegistryHighWaterMarkStore
    let clock: LockedHostClock
    let hostKey: SoftwareP256SigningKey
    let context: AuthenticatedDeviceContext
    let uploadID: UploadID
    let origin: OriginRecordingID
    let bytes: Data
    let codec: LoopbackRecordingEvidenceCodec
    let hostStore: HarcHostStore
    let recordingStore: RecordingStore
    let lease: HostWriterLease

    func service(
        hostStore: HarcHostStore? = nil,
        recordingStore: RecordingStore? = nil,
        lease: HostWriterLease? = nil,
        scheduler: any HostReceiptDurableProcessingScheduling,
        failureInjector: any HostPublicationFailureInjector = NoHostPublicationFailureInjector()
    ) throws -> HarcCanonicalIngestService {
        try HarcCanonicalIngestService(
            hostStore: hostStore ?? self.hostStore,
            recordingStore: recordingStore ?? self.recordingStore,
            canonicalCommitCapability: (lease ?? self.lease).canonicalCommitCapability,
            canonicalRoot: canonicalRoot,
            decoder: RawPCMFixtureHostChunkDecoder(),
            manifestValidator: codec,
            receiptIssuer: codec,
            receiptValidator: codec,
            hostAuthoritySigner: hostKey,
            processingScheduler: scheduler,
            failureInjector: failureInjector,
            now: { clock.read() }
        )
    }

    func reopen(
        scheduler: any HostReceiptDurableProcessingScheduling,
        failureInjector: any HostPublicationFailureInjector = NoHostPublicationFailureInjector()
    ) async throws -> (
        hostStore: HarcHostStore,
        recordingStore: RecordingStore,
        lease: HostWriterLease,
        service: HarcCanonicalIngestService
    ) {
        try await recordingStore.abandonHostLeaseForTesting(lease)
        let recovered = try await RecordingStore.recoverHostMode(
            onDiskAt: harcDatabaseURL,
            expectedLibraryID: metadata.libraryID,
            hostAuthorityID: metadata.hostAuthorityID,
            hostStateID: metadata.hostStateID,
            waitForLock: false
        )
        let reopenedHost = try await HarcHostStore.onDisk(
            databaseURL: hostDatabaseURL,
            stagingRoot: stagingRoot,
            metadata: metadata,
            highWaterMarkStore: highWaterMarkStore,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { clock.read() }
        )
        return (
            reopenedHost,
            recovered.store,
            recovered.lease,
            try service(
                hostStore: reopenedHost,
                recordingStore: recovered.store,
                lease: recovered.lease,
                scheduler: scheduler,
                failureInjector: failureInjector
            )
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Canonical ingest saga and receipt recovery", .serialized)
struct CanonicalIngestServiceTests {
    @Test(
        "every publication kill point recovers one row, one WAV, and the exact receipt",
        arguments: HostPublicationFailurePoint.allCases
    )
    func everyFailurePointRecoversExactlyOnce(
        _ point: HostPublicationFailurePoint
    ) async throws {
            let fixture = try await makePreparedIngest()
            let injector = OneShotPublicationFailureInjector(point)
            let scheduler = IdempotentProcessingScheduler()
            let service = try fixture.service(
                scheduler: scheduler,
                failureInjector: injector
            )

            var responseBeforeRestart: OpaqueExactObjectSlot?
            if point == .beforeProcessingSchedule
                || point == .afterProcessingScheduleBeforeCheckpoint
            {
                responseBeforeRestart = try await service.commitUpload(
                    context: fixture.context,
                    uploadID: fixture.uploadID,
                    generation: .initial
                )
                try await waitUntilTriggered(injector)
            } else {
                do {
                    _ = try await service.commitUpload(
                        context: fixture.context,
                        uploadID: fixture.uploadID,
                        generation: .initial
                    )
                    Issue.record("Expected injected crash at \(point.rawValue)")
                } catch let crash as InjectedPublicationCrash {
                    #expect(crash == .point(point))
                }
            }

            let persistedReceiptBytes = try await fixture.hostStore.dbReader.read { db in
                try Data.fetchOne(
                    db,
                    sql: "SELECT exact_receipt_bytes FROM publication_journal WHERE upload_id = ?",
                    arguments: [fixture.uploadID.description]
                )
            }
            let reopened = try await fixture.reopen(scheduler: scheduler)
            let recoveredReceipt = try await reopened.service.recoverPublication(
                uploadID: fixture.uploadID
            )

            if let responseBeforeRestart {
                #expect(recoveredReceipt == responseBeforeRestart)
            }
            if let persistedReceiptBytes {
                #expect(recoveredReceipt.exactBytes == persistedReceiptBytes)
            }
            let recordings = try await reopened.recordingStore.fetchAll()
            #expect(recordings.count == 1)
            let recording = try #require(recordings.first)
            #expect(recording.originID == fixture.origin)
            #expect(recording.processing == .pending)
            #expect(FileManager.default.fileExists(atPath: recording.wavPath))
            #expect(try canonicalWAVURLs(in: fixture.canonicalRoot).count == 1)

            let replay = try await reopened.service.commitUpload(
                context: fixture.context,
                uploadID: fixture.uploadID,
                generation: .initial
            )
            #expect(replay == recoveredReceipt)
            #expect(try await reopened.recordingStore.fetchAll().count == 1)
            #expect(try canonicalWAVURLs(in: fixture.canonicalRoot).count == 1)

            let schedule = await scheduler.snapshot()
            #expect(schedule.unique == 1)
            if point == .afterProcessingScheduleBeforeCheckpoint {
                #expect(schedule.attempts >= 2)
            }
            try await reopened.recordingStore.disableHostMode(reopened.lease)
            fixture.cleanup()
    }

    @Test("lost response and duplicate origin return byte-identical receipt without duplicate publication")
    func lostResponseAndDuplicateOriginAreIdempotent() async throws {
        let fixture = try await makePreparedIngest()
        defer { fixture.cleanup() }
        let injector = OneShotPublicationFailureInjector(.afterReceiptedCommit)
        let scheduler = IdempotentProcessingScheduler()
        let service = try fixture.service(
            scheduler: scheduler,
            failureInjector: injector
        )
        await #expect(throws: InjectedPublicationCrash.point(.afterReceiptedCommit)) {
            _ = try await service.commitUpload(
                context: fixture.context,
                uploadID: fixture.uploadID,
                generation: .initial
            )
        }
        let durableBytes = try #require(
            try await fixture.hostStore.dbReader.read { db in
                try Data.fetchOne(
                    db,
                    sql: "SELECT exact_receipt_bytes FROM publication_journal WHERE upload_id = ?",
                    arguments: [fixture.uploadID.description]
                )
            }
        )

        let reopened = try await fixture.reopen(scheduler: scheduler)
        let recovered = try await reopened.service.recoverPublication(uploadID: fixture.uploadID)
        #expect(recovered.exactBytes == durableBytes)
        let replay = try await reopened.service.commitUpload(
            context: fixture.context,
            uploadID: fixture.uploadID,
            generation: .initial
        )
        #expect(replay == recovered)

        let duplicateBegin = try await reopened.service.beginUpload(
            context: fixture.context,
            request: BeginHostUploadRequest(
                uploadID: .random(),
                originRecordingID: fixture.origin,
                frozenProfile: try fixtureProfile(),
                beganAt: fixture.clock.read()
            )
        )
        guard case .alreadyCommitted(let duplicateReceipt) = duplicateBegin else {
            Issue.record("Expected an already-committed origin replay")
            return
        }
        #expect(duplicateReceipt == recovered)
        #expect(try await reopened.recordingStore.fetchAll().count == 1)
        #expect(try canonicalWAVURLs(in: fixture.canonicalRoot).count == 1)
        try await reopened.recordingStore.disableHostMode(reopened.lease)
    }

    @Test("lost receipt response plus missing or replaced WAV blocks every receipt replay surface")
    func lostResponseThenWAVMutationBlocksAllReceiptReplay() async throws {
        for replaceWithSameBytes in [false, true] {
            let fixture = try await makePreparedIngest()
            let initialScheduler = IdempotentProcessingScheduler()
            let injector = OneShotPublicationFailureInjector(.afterReceiptedCommit)
            let service = try fixture.service(
                scheduler: initialScheduler,
                failureInjector: injector
            )
            await #expect(throws: InjectedPublicationCrash.point(.afterReceiptedCommit)) {
                _ = try await service.commitUpload(
                    context: fixture.context,
                    uploadID: fixture.uploadID,
                    generation: .initial
                )
            }
            let durableReceiptBytes = try #require(
                try await exactReceiptBytes(fixture.hostStore, fixture.uploadID)
            )
            let processing = try #require(
                try await fixture.hostStore.receiptProcessingWork(
                    uploadID: fixture.uploadID
                )
            )
            #expect(processing.exactReceipt.exactBytes == durableReceiptBytes)
            let paths = try publicationPaths(
                for: processing,
                canonicalRoot: fixture.canonicalRoot
            )
            let originalWAVBytes = try Data(contentsOf: paths.wavURL)
            try FileManager.default.removeItem(at: paths.wavURL)
            if replaceWithSameBytes {
                try originalWAVBytes.write(to: paths.wavURL, options: .withoutOverwriting)
                guard chmod(paths.wavURL.path, 0o600) == 0 else {
                    throw HarcHostError.publicationIO("Could not secure replacement WAV.")
                }
            }

            let recoveryScheduler = IdempotentProcessingScheduler()
            let reopened = try await fixture.reopen(scheduler: recoveryScheduler)
            await #expect(throws: (any Error).self) {
                _ = try await reopened.service.recoverPublication(
                    uploadID: fixture.uploadID
                )
            }
            await #expect(throws: (any Error).self) {
                _ = try await reopened.service.beginUpload(
                    context: fixture.context,
                    request: BeginHostUploadRequest(
                        uploadID: .random(),
                        originRecordingID: fixture.origin,
                        frozenProfile: try fixtureProfile(),
                        beganAt: fixture.clock.read()
                    )
                )
            }
            await #expect(throws: (any Error).self) {
                _ = try await reopened.service.reconcileUpload(
                    for: fixture.uploadID,
                    context: fixture.context
                )
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            let initialSnapshot = await initialScheduler.snapshot()
            let recoverySnapshot = await recoveryScheduler.snapshot()
            #expect(initialSnapshot.attempts == 0)
            #expect(recoverySnapshot.attempts == 0)
            #expect(
                try await exactReceiptBytes(reopened.hostStore, fixture.uploadID)
                    == durableReceiptBytes
            )
            try await reopened.recordingStore.disableHostMode(reopened.lease)
            fixture.cleanup()
        }
    }

    @Test("processing failure never retracts playable committed audio or its receipt")
    func processingFailureLeavesReceiptedPlayableAudio() async throws {
        let fixture = try await makePreparedIngest()
        defer { fixture.cleanup() }
        let scheduler = FailingProcessingScheduler()
        let service = try fixture.service(scheduler: scheduler)
        let receipt = try await service.commitUpload(
            context: fixture.context,
            uploadID: fixture.uploadID,
            generation: .initial
        )
        try await waitForSchedulerAttempt(scheduler)

        let recording = try #require(try await fixture.recordingStore.fetchAll().first)
        #expect(recording.processing == .pending)
        #expect(FileManager.default.fileExists(atPath: recording.wavPath))
        let processing = try #require(
            try await fixture.hostStore.receiptProcessingWork(uploadID: fixture.uploadID)
        )
        #expect(processing.state == .receipted)
        #expect(processing.exactReceipt == receipt)
        #expect(try canonicalWAVURLs(in: fixture.canonicalRoot).count == 1)
        try await fixture.recordingStore.disableHostMode(fixture.lease)
    }

    @Test("an occupied canonical destination is preserved and publication resumes after removal")
    func conflictingDestinationIsNeverOverwritten() async throws {
        let fixture = try await makePreparedIngest()
        defer { fixture.cleanup() }
        let scheduler = IdempotentProcessingScheduler()
        let injector = OneShotPublicationFailureInjector(.afterPublicationPlan)
        let service = try fixture.service(
            scheduler: scheduler,
            failureInjector: injector
        )
        await #expect(throws: InjectedPublicationCrash.point(.afterPublicationPlan)) {
            _ = try await service.commitUpload(
                context: fixture.context,
                uploadID: fixture.uploadID,
                generation: .initial
            )
        }

        let work = try await publicationWork(for: fixture)
        let paths = try publicationPaths(for: work, canonicalRoot: fixture.canonicalRoot)
        let conflictBytes = Data("pre-existing canonical destination".utf8)
        try writeExclusive(conflictBytes, to: paths.wavURL, in: paths)

        await #expect(throws: HarcHostError.canonicalDestinationExists) {
            _ = try await service.recoverPublication(uploadID: fixture.uploadID)
        }
        #expect(try Data(contentsOf: paths.wavURL) == conflictBytes)
        #expect(try await fixture.recordingStore.fetchAll().isEmpty)
        #expect(try canonicalWAVURLs(in: fixture.canonicalRoot).count == 1)

        try paths.removeOwnedRegularFileIfPresent(at: paths.wavURL)
        try paths.synchronizeDirectory()
        let receipt = try await service.recoverPublication(uploadID: fixture.uploadID)
        #expect(!receipt.exactBytes.isEmpty)
        #expect(try await fixture.recordingStore.fetchAll().count == 1)
        #expect(try canonicalWAVURLs(in: fixture.canonicalRoot).count == 1)
        try await fixture.recordingStore.disableHostMode(fixture.lease)
    }

    @Test("audio-renamed checkpoint without a final file fails closed on restart")
    func audioRenamedCheckpointWithoutFinalFileFailsClosed() async throws {
        let fixture = try await makePreparedIngest()
        defer { fixture.cleanup() }
        let scheduler = IdempotentProcessingScheduler()
        let injector = OneShotPublicationFailureInjector(.afterPublicationPlan)
        let service = try fixture.service(
            scheduler: scheduler,
            failureInjector: injector
        )
        await #expect(throws: InjectedPublicationCrash.point(.afterPublicationPlan)) {
            _ = try await service.commitUpload(
                context: fixture.context,
                uploadID: fixture.uploadID,
                generation: .initial
            )
        }

        let work = try await publicationWork(for: fixture)
        let paths = try publicationPaths(for: work, canonicalRoot: fixture.canonicalRoot)
        let assembler = try HostCanonicalWAVAssembler(
            paths: paths,
            totalFrames: work.capture.capture.totalCanonicalFrames
        )
        try assembler.appendCanonicalPCM(fixture.bytes)
        _ = try assembler.synchronizeAndClose(
            expectedPCMHash: work.capture.capture.canonicalPCMSHA256
        )
        try paths.synchronizeDirectory()
        try await fixture.hostStore.markPublicationCheckpoint(
            uploadID: fixture.uploadID,
            expected: [.assembling],
            next: .temporarySynchronized,
            at: fixture.clock.read()
        )
        // This deliberately creates an impossible durable permutation. The
        // real publisher fsyncs the directory after rename and before storing
        // `.audioRenamed`; recovery must not reinterpret the old temp as final.
        try await fixture.hostStore.markPublicationCheckpoint(
            uploadID: fixture.uploadID,
            expected: [.temporarySynchronized],
            next: .audioRenamed,
            at: fixture.clock.read()
        )

        let reopened = try await fixture.reopen(scheduler: scheduler)
        do {
            _ = try await reopened.service.recoverPublication(uploadID: fixture.uploadID)
            Issue.record("Expected impossible audio-renamed state to fail closed")
        } catch let error as HarcHostError {
            guard case .publicationIO = error else {
                Issue.record("Unexpected fail-closed error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected non-host fail-closed error: \(error)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: paths.temporaryURL.path))
        #expect(!FileManager.default.fileExists(atPath: paths.wavURL.path))
        #expect(try await reopened.recordingStore.fetchAll().isEmpty)
        #expect(try canonicalWAVURLs(in: fixture.canonicalRoot).isEmpty)
        let state = try await reopened.hostStore.dbReader.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT state FROM publication_journal WHERE upload_id = ?",
                arguments: [fixture.uploadID.description]
            )
        }
        #expect(state == HostUploadJournalState.failedRecoverable.rawValue)
        try await reopened.recordingStore.disableHostMode(reopened.lease)
    }

    @Test("moved canonical root after Host linkage yields no receipt or replacement-root sidecars")
    func movedRootAfterHostLinkageFailsAcrossLiveAndRestartedService() async throws {
        let fixture = try await makePreparedIngest()
        defer { fixture.cleanup() }
        let scheduler = IdempotentProcessingScheduler()
        let injector = OneShotPublicationFailureInjector(.afterHostPublicationLinkage)
        let service = try fixture.service(
            scheduler: scheduler,
            failureInjector: injector
        )
        await #expect(throws: InjectedPublicationCrash.point(.afterHostPublicationLinkage)) {
            _ = try await service.commitUpload(
                context: fixture.context,
                uploadID: fixture.uploadID,
                generation: .initial
            )
        }
        _ = try await publicationWork(for: fixture)

        let movedRoot = fixture.root.appendingPathComponent(
            "canonical-moved-aside",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: fixture.canonicalRoot, to: movedRoot)
        try FileManager.default.createDirectory(
            at: fixture.canonicalRoot,
            withIntermediateDirectories: false
        )
        guard chmod(fixture.canonicalRoot.path, 0o700) == 0 else {
            throw HarcHostError.publicationIO("Could not secure replacement canonical root.")
        }

        await expectRecoveryFailure(service, uploadID: fixture.uploadID)
        #expect(try await exactReceiptBytes(fixture.hostStore, fixture.uploadID) == nil)
        #expect(try canonicalSidecarURLs(in: fixture.canonicalRoot).isEmpty)

        let reopened = try await fixture.reopen(scheduler: scheduler)
        await expectRecoveryFailure(reopened.service, uploadID: fixture.uploadID)
        #expect(try await exactReceiptBytes(reopened.hostStore, fixture.uploadID) == nil)
        #expect(try canonicalSidecarURLs(in: fixture.canonicalRoot).isEmpty)
        #expect(try await reopened.recordingStore.fetchAll().count == 1)
        try await reopened.recordingStore.disableHostMode(reopened.lease)
    }

    @Test("missing or replaced WAV before finalization never publishes sidecars or commits receipt")
    func wavMutationBeforeReceiptFinalizationFailsClosed() async throws {
        for replaceWithSameBytes in [false, true] {
            let fixture = try await makePreparedIngest()
            let scheduler = IdempotentProcessingScheduler()
            let injector = OneShotPublicationFailureInjector(.afterReceiptPersistence)
            let service = try fixture.service(
                scheduler: scheduler,
                failureInjector: injector
            )
            await #expect(throws: InjectedPublicationCrash.point(.afterReceiptPersistence)) {
                _ = try await service.commitUpload(
                    context: fixture.context,
                    uploadID: fixture.uploadID,
                    generation: .initial
                )
            }
            let work = try await publicationWork(for: fixture)
            let paths = try publicationPaths(
                for: work,
                canonicalRoot: fixture.canonicalRoot
            )
            let originalBytes = try Data(contentsOf: paths.wavURL)
            try FileManager.default.removeItem(at: paths.wavURL)
            if replaceWithSameBytes {
                try originalBytes.write(to: paths.wavURL, options: .withoutOverwriting)
                guard chmod(paths.wavURL.path, 0o600) == 0 else {
                    throw HarcHostError.publicationIO("Could not secure replacement WAV.")
                }
            }

            let reopened = try await fixture.reopen(scheduler: scheduler)
            await expectRecoveryFailure(reopened.service, uploadID: fixture.uploadID)
            #expect(try canonicalSidecarURLs(in: fixture.canonicalRoot).isEmpty)
            #expect(try await reopened.hostStore.receiptProcessingWork(
                uploadID: fixture.uploadID
            ) == nil)
            let status = try await reopened.hostStore.dbReader.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT attempt_status FROM uploads WHERE upload_id = ?",
                    arguments: [fixture.uploadID.description]
                )
            }
            #expect(status == UploadAttemptStatus.active.rawValue)
            try await reopened.recordingStore.disableHostMode(reopened.lease)
            fixture.cleanup()
        }
    }

    @Test("replaced WAV after receipt remains retryable and never reaches scheduler or replay")
    func wavReplacementAfterReceiptBlocksProcessingAndReceiptReplay() async throws {
        let fixture = try await makePreparedIngest()
        defer { fixture.cleanup() }
        let initialScheduler = IdempotentProcessingScheduler()
        let injector = OneShotPublicationFailureInjector(.beforeProcessingSchedule)
        let service = try fixture.service(
            scheduler: initialScheduler,
            failureInjector: injector
        )
        let originalReceipt = try await service.commitUpload(
            context: fixture.context,
            uploadID: fixture.uploadID,
            generation: .initial
        )
        try await waitUntilTriggered(injector)
        let processing = try #require(
            try await fixture.hostStore.receiptProcessingWork(uploadID: fixture.uploadID)
        )
        let paths = try publicationPaths(
            for: processing,
            canonicalRoot: fixture.canonicalRoot
        )
        let originalBytes = try Data(contentsOf: paths.wavURL)
        try FileManager.default.removeItem(at: paths.wavURL)
        try originalBytes.write(to: paths.wavURL, options: .withoutOverwriting)
        guard chmod(paths.wavURL.path, 0o600) == 0 else {
            throw HarcHostError.publicationIO("Could not secure replacement WAV.")
        }

        let recoveryScheduler = IdempotentProcessingScheduler()
        let reopened = try await fixture.reopen(scheduler: recoveryScheduler)
        await expectRecoveryFailure(reopened.service, uploadID: fixture.uploadID)
        let recoverySnapshot = await recoveryScheduler.snapshot()
        #expect(recoverySnapshot.attempts == 0)
        let retryable = try #require(
            try await reopened.hostStore.receiptProcessingWork(uploadID: fixture.uploadID)
        )
        #expect(retryable.state == .receipted)
        #expect(retryable.exactReceipt == originalReceipt)

        await #expect(throws: (any Error).self) {
            _ = try await reopened.service.beginUpload(
                context: fixture.context,
                request: BeginHostUploadRequest(
                    uploadID: .random(),
                    originRecordingID: fixture.origin,
                    frozenProfile: try fixtureProfile(),
                    beganAt: fixture.clock.read()
                )
            )
        }
        let replaySnapshot = await recoveryScheduler.snapshot()
        #expect(replaySnapshot.attempts == 0)
        try await reopened.recordingStore.disableHostMode(reopened.lease)
    }

    @Test("missing or replaced WAV rejects cleanup-authorizing reconciliation receipt")
    func wavMutationAfterReceiptBlocksReconciliationReplay() async throws {
        for replaceWithSameBytes in [false, true] {
            let fixture = try await makePreparedIngest()
            let scheduler = IdempotentProcessingScheduler()
            let injector = OneShotPublicationFailureInjector(.beforeProcessingSchedule)
            let service = try fixture.service(
                scheduler: scheduler,
                failureInjector: injector
            )
            _ = try await service.commitUpload(
                context: fixture.context,
                uploadID: fixture.uploadID,
                generation: .initial
            )
            try await waitUntilTriggered(injector)
            let processing = try #require(
                try await fixture.hostStore.receiptProcessingWork(
                    uploadID: fixture.uploadID
                )
            )
            let paths = try publicationPaths(
                for: processing,
                canonicalRoot: fixture.canonicalRoot
            )
            let originalBytes = try Data(contentsOf: paths.wavURL)
            try FileManager.default.removeItem(at: paths.wavURL)
            if replaceWithSameBytes {
                try originalBytes.write(to: paths.wavURL, options: .withoutOverwriting)
                guard chmod(paths.wavURL.path, 0o600) == 0 else {
                    throw HarcHostError.publicationIO("Could not secure replacement WAV.")
                }
            }

            await #expect(throws: (any Error).self) {
                _ = try await service.reconcileUpload(
                    for: fixture.uploadID,
                    context: fixture.context
                )
            }
            let snapshot = await scheduler.snapshot()
            #expect(snapshot.attempts == 0)
            try await fixture.recordingStore.disableHostMode(fixture.lease)
            fixture.cleanup()
        }
    }
}

private extension CanonicalIngestServiceTests {
    func makePreparedIngest() async throws -> PreparedCanonicalIngest {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "harc-canonical-ingest-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard chmod(root.path, 0o700) == 0 else {
            throw HarcHostError.publicationIO("Could not secure the test root.")
        }
        let harcDatabaseURL = root.appendingPathComponent("Harc.db")
        let hostDatabaseURL = root.appendingPathComponent("HarcHost.db")
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let canonicalRoot = root.appendingPathComponent("canonical", isDirectory: true)

        let recordingStore = try await RecordingStore.onDisk(url: harcDatabaseURL)
        let libraryID = try await recordingStore.libraryMetadata().libraryID
        let hostKey = SoftwareP256SigningKey()
        let deviceKey = SoftwareP256SigningKey()
        let metadata = HarcHostMetadata(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            hostStateID: .random()
        )
        let milliseconds = floor(Date().timeIntervalSince1970 * 1_000) - 60_000
        let base = Date(timeIntervalSince1970: milliseconds / 1_000)
        let clock = LockedHostClock(base)
        let highWater = InMemorySecurityRegistryHighWaterMarkStore()
        let hostStore = try await HarcHostStore.onDisk(
            databaseURL: hostDatabaseURL,
            stagingRoot: stagingRoot,
            metadata: metadata,
            highWaterMarkStore: highWater,
            capacityProvider: FixedHostVolumeCapacityProvider(),
            now: { clock.read() }
        )
        let grant = try DeviceGrantClaims(
            libraryID: libraryID,
            hostAuthorityID: metadata.hostAuthorityID,
            grantID: .random(),
            devicePublicKey: deviceKey.publicKey,
            scopes: [.recordingUploadOwn, .recordingReadOwn],
            grantEpoch: .initial,
            issuedAt: base.addingTimeInterval(-1),
            expiresAt: nil,
            minimumCompatibleProtocolMinor: 0,
            maximumCompatibleProtocolMinor: 0
        )
        try await hostStore.seedDeviceGrantForTesting(
            grant,
            exactGrantBytes: Data("fixture-grant".utf8)
        )
        let context = AuthenticatedDeviceContext(
            libraryID: libraryID,
            hostAuthorityID: metadata.hostAuthorityID,
            authenticatedDeviceID: deviceKey.publicKey.deviceID,
            grantID: grant.grantID,
            grantEpoch: grant.grantEpoch
        )
        let uploadID = UploadID.random()
        let origin = OriginRecordingID(
            deviceID: deviceKey.publicKey.deviceID,
            recordingUUID: UUID()
        )
        let bytes = Data((0 ..< 8_192).map { UInt8(truncatingIfNeeded: $0) })
        let digest = Data(SHA256.hash(data: bytes))
        let descriptor = try LogicalChunkDescriptor(
            originRecordingID: origin,
            chunkID: .random(),
            chunkIndex: 0,
            canonicalStartFrame: 0,
            canonicalFrameCount: UInt64(bytes.count / 2),
            encoding: .rawPCMFixture,
            encodedByteLength: UInt64(bytes.count),
            encodedSHA256: EncodedChunkSHA256(digest),
            canonicalDecodedByteLength: UInt64(bytes.count),
            canonicalDecodedSHA256: CanonicalPCMHash(digest)
        )
        let profile = try fixtureProfile()

        _ = try await hostStore.beginUpload(
            context: context,
            request: BeginHostUploadRequest(
                uploadID: uploadID,
                originRecordingID: origin,
                frozenProfile: profile,
                beganAt: base
            )
        )
        clock.set(base.addingTimeInterval(1))
        _ = try await hostStore.declareChunks(
            context: context,
            uploadID: uploadID,
            generation: .initial,
            descriptors: [descriptor]
        )
        clock.set(base.addingTimeInterval(2))
        _ = try await hostStore.stageChunk(
            context: context,
            uploadID: uploadID,
            generation: .initial,
            chunkIndex: 0,
            declaredEncodedLength: UInt64(bytes.count),
            bodyFragments: [bytes]
        )
        let capture = try FinalizedCapture(
            producingDeviceID: deviceKey.publicKey.deviceID,
            originRecordingID: origin,
            captureStartedAt: base.addingTimeInterval(-30),
            captureEndedAt: base.addingTimeInterval(-29),
            captureStartedMonotonicNanoseconds: 100,
            captureEndedMonotonicNanoseconds: 200,
            finalizationReason: .userStopped,
            totalCanonicalFrames: UInt64(bytes.count / 2),
            totalCanonicalBytes: UInt64(bytes.count),
            canonicalPCMSHA256: CanonicalPCMHash(digest),
            discontinuities: []
        )
        let chunked = try ChunkedFinalizedCapture(
            capture: capture,
            chunks: [descriptor]
        )
        let manifestBytes = Data("fixture-manifest-\(uploadID.description)".utf8)
        let manifestObject = try OpaqueExactObjectSlot(
            kind: .recordingManifestV1,
            exactBytes: manifestBytes,
            objectSHA256: ExactObjectSHA256(Data(SHA256.hash(data: manifestBytes)))
        )
        let hostTrust = try RecordingHostTrustBinding(
            libraryID: libraryID,
            hostAuthorityID: metadata.hostAuthorityID,
            hostAuthorityPublicKey: hostKey.publicKey
        )
        let manifestEvidence = try ValidatedRecordingManifestEvidence(
            hostTrust: hostTrust,
            exactManifestObject: manifestObject,
            uploadID: uploadID,
            producingDevicePublicKey: deviceKey.publicKey,
            originRecordingID: origin,
            uploadProfileSHA256: profile.profileSHA256,
            finalizedCapture: chunked
        )
        clock.set(base.addingTimeInterval(3))
        _ = try await hostStore.bindFinalManifestForPrecommit(
            context: context,
            uploadID: uploadID,
            generation: .initial,
            evidence: manifestEvidence
        )
        clock.set(base.addingTimeInterval(4))
        let lease = try await recordingStore.enableHostMode(
            expectedLibraryID: libraryID,
            hostAuthorityID: metadata.hostAuthorityID,
            hostStateID: metadata.hostStateID
        )

        return PreparedCanonicalIngest(
            root: root,
            harcDatabaseURL: harcDatabaseURL,
            hostDatabaseURL: hostDatabaseURL,
            stagingRoot: stagingRoot,
            canonicalRoot: canonicalRoot,
            metadata: metadata,
            highWaterMarkStore: highWater,
            clock: clock,
            hostKey: hostKey,
            context: context,
            uploadID: uploadID,
            origin: origin,
            bytes: bytes,
            codec: LoopbackRecordingEvidenceCodec(manifest: manifestEvidence),
            hostStore: hostStore,
            recordingStore: recordingStore,
            lease: lease
        )
    }

    func waitUntilTriggered(
        _ injector: OneShotPublicationFailureInjector
    ) async throws {
        for _ in 0 ..< 200 {
            if await injector.wasTriggered() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("Timed out waiting for the asynchronous publication failure point")
        throw HarcHostError.databaseFailure("Test failure point did not trigger.")
    }

    func publicationWork(
        for fixture: PreparedCanonicalIngest
    ) async throws -> HostCanonicalPublicationWork {
        let preparation = try await fixture.hostStore.canonicalPublicationForRecovery(
            uploadID: fixture.uploadID
        )
        guard case .work(let work) = preparation else {
            throw HarcHostError.databaseFailure("Expected canonical publication work.")
        }
        return work
    }

    func publicationPaths(
        for work: HostCanonicalPublicationWork,
        canonicalRoot: URL
    ) throws -> HostCanonicalPublicationPaths {
        try HostCanonicalPublicationPaths.make(
            root: canonicalRoot,
            canonicalRecordingID: work.canonicalRecordingID,
            persistedRelativeWAVPath: work.publicationRelativePath,
            temporaryName: work.temporaryName
        )
    }

    func publicationPaths(
        for work: HostReceiptProcessingWork,
        canonicalRoot: URL
    ) throws -> HostCanonicalPublicationPaths {
        try HostCanonicalPublicationPaths.make(
            root: canonicalRoot,
            canonicalRecordingID: work.canonicalRecordingID,
            persistedRelativeWAVPath: work.publicationRelativePath,
            temporaryName: work.temporaryName
        )
    }

    func expectRecoveryFailure(
        _ service: HarcCanonicalIngestService,
        uploadID: UploadID
    ) async {
        do {
            _ = try await service.recoverPublication(uploadID: uploadID)
            Issue.record("Expected canonical artifact recovery to fail closed")
        } catch {}
    }

    func exactReceiptBytes(
        _ store: HarcHostStore,
        _ uploadID: UploadID
    ) async throws -> Data? {
        try await store.dbReader.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT exact_receipt_bytes FROM publication_journal WHERE upload_id = ?",
                arguments: [uploadID.description]
            )
        }
    }

    func canonicalSidecarURLs(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension == "harc-manifest"
                    || url.pathExtension == "harc-receipt"
            else { return nil }
            return url
        }
    }

    func writeExclusive(
        _ bytes: Data,
        to url: URL,
        in paths: HostCanonicalPublicationPaths
    ) throws {
        let descriptor = try paths.createExclusiveFile(at: url)
        var isOpen = true
        defer {
            if isOpen { _ = Darwin.close(descriptor) }
        }
        try bytes.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw HarcHostError.publicationIO(
                        "Could not write the test conflict: errno \(errno)."
                    )
                }
            }
        }
        guard fsync(descriptor) == 0 else {
            throw HarcHostError.publicationIO(
                "Could not synchronize the test conflict: errno \(errno)."
            )
        }
        try paths.validateOpenFile(descriptor, at: url)
        guard Darwin.close(descriptor) == 0 else {
            throw HarcHostError.publicationIO(
                "Could not close the test conflict: errno \(errno)."
            )
        }
        isOpen = false
        try paths.synchronizeDirectory()
    }

    func waitForSchedulerAttempt(_ scheduler: FailingProcessingScheduler) async throws {
        for _ in 0 ..< 200 {
            if await scheduler.attemptCount() > 0 { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("Timed out waiting for the processing scheduler")
        throw HarcHostError.databaseFailure("Test scheduler did not run.")
    }

    func fixtureProfile() throws -> FrozenUploadProfile {
        try FrozenUploadProfile(
            protocolVersion: TransferProtocolVersion(minor: 0),
            encoding: .rawPCMFixture,
            requiredCapabilities: [],
            negotiatedCapabilitiesSHA256: NegotiatedCapabilitiesSHA256(
                Data(repeating: 0x61, count: 32)
            ),
            profileSHA256: UploadProfileSHA256(Data(repeating: 0x62, count: 32)),
            purpose: .fixtureLoopback
        )
    }

    func canonicalWAVURLs(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "wav" else { return nil }
            return url
        }
    }
}
