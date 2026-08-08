import Foundation
import GRDB
import HarcDomain
import HarcTransfer
import Testing
@testable import HarcClientStore

@Suite("HarcTransferStore durable outbox")
struct OutboxPersistenceTests {
    @Test("recording outbox enumeration survives relaunch in capture order")
    func durableRecordingEnumeration() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = RecordingStorageAttributes()
        let first = ClientStoreFixtures.origin(recording: 41)
        let second = ClientStoreFixtures.origin(recording: 42)
        do {
            let store = try HarcTransferStore(
                rootDirectory: root,
                installationDeviceID: first.deviceID,
                storageAttributes: attributes
            )
            _ = try store.persistFinalizedCapture(
                ClientStoreFixtures.capture(origin: second),
                masterFileURL: root.appendingPathComponent("second.wav"),
                persistedAt: ClientStoreFixtures.baseDate
                    .addingTimeInterval(2)
            )
            _ = try store.persistFinalizedCapture(
                ClientStoreFixtures.capture(origin: first),
                masterFileURL: root.appendingPathComponent("first.wav"),
                persistedAt: ClientStoreFixtures.baseDate
                    .addingTimeInterval(1)
            )
        }

        let reopened = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: first.deviceID,
            storageAttributes: attributes
        )
        #expect(try reopened.recordingOutboxes().map {
            $0.finalizedCapture.capture.originRecordingID
        } == [first, second])
    }

    @Test("capture, upload, chunk, credential, and task state survive reopen")
    func durableReopenAndReconciliation() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = RecordingStorageAttributes()
        let tuple = ClientStoreFixtures.tuple(library: 1, authorityByte: 1)
        let origin = ClientStoreFixtures.origin()
        let capture = ClientStoreFixtures.capture(origin: origin)
        let attempt = ClientStoreFixtures.attempt(origin: origin)
        let chunk = ClientStoreFixtures.chunk(origin: origin)
        let batch = ClientStoreFixtures.batch(origin: origin, uploadID: attempt.uploadID)
        let masterURL = root.appendingPathComponent("artifacts/master.wav")
        let chunkURL = root.appendingPathComponent("artifacts/chunk-0.caf")
        let batchURL = root.appendingPathComponent("artifacts/batch-0.bin")
        let capability = try OpaqueBackgroundCapability(
            credential: Data([0xCA, 0xFE]),
            capabilityBindings: Data([0xBA, 0xBE]),
            expiresAt: ClientStoreFixtures.baseDate.addingTimeInterval(3_600)
        )
        let task = try SystemBackgroundTaskIdentity(taskIdentifier: 42)

        do {
            let store = try HarcTransferStore(
                rootDirectory: root,
                installationDeviceID: origin.deviceID,
                storageAttributes: attributes
            )
            _ = try store.adopt(
                ClientStoreFixtures.adoption(
                    tuple: tuple,
                    keyByte: 1,
                    transportEpoch: 1,
                    transportByte: 1,
                    grantEpoch: 1,
                    grantByte: 1
                )
            )
            _ = try store.persistFinalizedCapture(
                capture,
                masterFileURL: masterURL
            )
            _ = try store.updateRecordingOutbox(for: origin) { machine in
                try machine.queue()
                try machine.beginAuthorization()
                try machine.beginActiveUpload()
            }
            try store.persistUploadAttempt(attempt, for: tuple)

            var chunkMachine = ChunkOutboxStateMachine()
            try chunkMachine.beginEncoding()
            try chunkMachine.markReady()
            try store.persistEncodedChunk(
                uploadID: attempt.uploadID,
                descriptor: chunk,
                encodedFileURL: chunkURL,
                stateMachine: chunkMachine
            )
            try store.persistBackgroundBatch(
                batch,
                bodyFileURL: batchURL,
                capability: capability
            )
            try store.persistTaskMappingBeforeResume(task, batchID: batch.batchID)
        }

        let reopened = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: origin.deviceID,
            storageAttributes: attributes
        )
        let storedOutbox = try #require(try reopened.recordingOutbox(for: origin))
        #expect(storedOutbox.uploadID == attempt.uploadID)
        #expect(storedOutbox.stateMachine.state == .activeUpload)
        #expect(storedOutbox.finalizedCapture.capture == capture)
        let storedAttempt = try #require(try reopened.uploadAttempt(id: attempt.uploadID))
        #expect(storedAttempt.attempt == attempt)
        #expect(storedAttempt.trustTuple == tuple)
        let chunks = try reopened.chunks(uploadID: attempt.uploadID)
        #expect(chunks.count == 1)
        #expect(chunks[0].descriptor == chunk)
        #expect(chunks[0].stateMachine.state == .ready)
        let storedBatch = try #require(try reopened.backgroundBatch(id: batch.batchID))
        #expect(storedBatch.descriptor == batch)
        #expect(storedBatch.capability == capability)
        #expect(storedBatch.bodyFileURL == batchURL.standardizedFileURL)
        let mappings = try reopened.taskMappings()
        #expect(mappings.count == 1)
        #expect(mappings[0].identity == task)
        #expect(mappings[0].state == .persistedBeforeResume)

        let taskResult = try reopened.reconcileBackgroundTasks(observedSystemTasks: [])
        #expect(taskResult.batchesToReschedule == [batch.batchID])
        #expect(taskResult.orphanedSystemTasks.isEmpty)
        #expect(try reopened.taskMappings()[0].state == .missingFromSystem)

        let inspector = StubArtifactInspector(existingURLs: [])
        let artifacts = try reopened.reconcileLocalArtifacts(inspector: inspector)
        #expect(artifacts.missingMasters == [origin])
        #expect(artifacts.missingChunks == [chunk.chunkID])
        #expect(artifacts.missingBatches == [batch.batchID])
        #expect(artifacts.mismatchedChunks.isEmpty)
        #expect(artifacts.mismatchedBatches.isEmpty)
        #expect(try reopened.recordingOutbox(for: origin)?.stateMachine.state == .securityBlocked)
        #expect(try reopened.recordingOutbox(for: origin)?.integrityBlock != nil)
        #expect(try reopened.chunks(uploadID: attempt.uploadID)[0].stateMachine.state == .ready)
        #expect(try reopened.backgroundBatch(id: batch.batchID)?.state == .needsReschedule)
        // Missing-file reconciliation preserves every row and opaque secret.
        #expect(try reopened.backgroundBatch(id: batch.batchID)?.capability.credential == capability.credential)
    }

    @Test("upload supersession is atomic and preserves attempt history")
    func explicitAbandonmentSupersession() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = RecordingStorageAttributes()
        let origin = ClientStoreFixtures.origin()
        let tuple = ClientStoreFixtures.tuple(library: 1, authorityByte: 1)
        let store = try HarcTransferStore(
            databaseURL: ClientStoreLocations(rootDirectory: root).transferDatabase,
            installationDeviceID: origin.deviceID,
            storageAttributes: attributes
        )
        _ = try store.adopt(
            ClientStoreFixtures.adoption(
                tuple: tuple,
                keyByte: 1,
                transportEpoch: 1,
                transportByte: 1,
                grantEpoch: 1,
                grantByte: 1
            )
        )
        _ = try store.persistFinalizedCapture(
            ClientStoreFixtures.capture(origin: origin),
            masterFileURL: root.appendingPathComponent("master.wav")
        )
        let first = ClientStoreFixtures.attempt(origin: origin)
        try store.persistUploadAttempt(first, for: tuple)
        let replacement = ClientStoreFixtures.attempt(
            origin: origin,
            uploadID: UploadID(ClientStoreFixtures.uuid(301)),
            beganAt: ClientStoreFixtures.baseDate.addingTimeInterval(2)
        )

        // An active attempt cannot silently lose the recording binding. The
        // replacement insert and outbox change both roll back.
        #expect(throws: ClientStoreError.self) {
            try store.persistUploadAttempt(
                replacement,
                for: tuple,
                updatedAt: ClientStoreFixtures.baseDate.addingTimeInterval(2)
            )
        }
        #expect(try store.uploadAttempt(id: replacement.uploadID) == nil)
        #expect(try store.recordingOutbox(for: origin)?.uploadID == first.uploadID)

        var abandoned = first
        try abandoned.abandon(at: ClientStoreFixtures.baseDate.addingTimeInterval(1))
        let tooEarly = ClientStoreFixtures.attempt(
            origin: origin,
            uploadID: UploadID(ClientStoreFixtures.uuid(305)),
            beganAt: ClientStoreFixtures.baseDate
        )
        #expect(throws: ClientStoreError.self) {
            try store.persistUploadAttempt(
                tooEarly,
                for: tuple,
                abandoning: abandoned,
                updatedAt: ClientStoreFixtures.baseDate.addingTimeInterval(2)
            )
        }
        // The prior abandonment was part of the failed transaction.
        #expect(try store.uploadAttempt(id: first.uploadID)?.attempt.status == .active)
        #expect(try store.uploadAttempt(id: tooEarly.uploadID) == nil)

        let sameBoundary = ClientStoreFixtures.attempt(
            origin: origin,
            uploadID: UploadID(ClientStoreFixtures.uuid(307)),
            beganAt: ClientStoreFixtures.baseDate.addingTimeInterval(1)
        )
        #expect(throws: ClientStoreError.uploadRebindNotAllowed(
            current: first.uploadID,
            presented: sameBoundary.uploadID
        )) {
            try store.persistUploadAttempt(
                sameBoundary,
                for: tuple,
                abandoning: abandoned,
                updatedAt: ClientStoreFixtures.baseDate.addingTimeInterval(1)
            )
        }
        #expect(try store.uploadAttempt(id: first.uploadID)?.attempt.status == .active)
        #expect(try store.uploadAttempt(id: sameBoundary.uploadID) == nil)

        try store.persistUploadAttempt(
            replacement,
            for: tuple,
            abandoning: abandoned,
            updatedAt: ClientStoreFixtures.baseDate.addingTimeInterval(2)
        )
        #expect(try store.uploadAttempt(id: first.uploadID)?.attempt.status == .abandoned)
        #expect(try store.uploadAttempt(id: replacement.uploadID)?.attempt == replacement)
        #expect(try store.recordingOutbox(for: origin)?.uploadID == replacement.uploadID)
        #expect(try store.recordingOutbox(for: origin)?.stateMachine.state == .queued)

        let reopened = try HarcTransferStore(
            databaseURL: ClientStoreLocations(rootDirectory: root).transferDatabase,
            installationDeviceID: origin.deviceID,
            storageAttributes: attributes
        )
        #expect(try reopened.uploadAttempt(id: first.uploadID)?.attempt.status == .abandoned)
        #expect(try reopened.uploadAttempt(id: replacement.uploadID)?.attempt == replacement)
        #expect(try reopened.recordingOutbox(for: origin)?.uploadID == replacement.uploadID)
    }

    @Test("an expired attempt may be replaced but a conflict-blocked attempt may not")
    func expirySupersession() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = ClientStoreFixtures.origin()
        let tuple = ClientStoreFixtures.tuple(library: 1, authorityByte: 1)
        let first = ClientStoreFixtures.attempt(origin: origin)
        let afterExpiry = first.generationExpiresAt.addingTimeInterval(1)
        let store = try HarcTransferStore(
            databaseURL: ClientStoreLocations(rootDirectory: root).transferDatabase,
            installationDeviceID: origin.deviceID,
            storageAttributes: RecordingStorageAttributes(),
            now: { afterExpiry }
        )
        _ = try store.adopt(
            ClientStoreFixtures.adoption(
                tuple: tuple,
                keyByte: 1,
                transportEpoch: 1,
                transportByte: 1,
                grantEpoch: 1,
                grantByte: 1
            )
        )
        _ = try store.persistFinalizedCapture(
            ClientStoreFixtures.capture(origin: origin),
            masterFileURL: root.appendingPathComponent("master.wav")
        )
        try store.persistUploadAttempt(first, for: tuple)
        let replacement = ClientStoreFixtures.attempt(
            origin: origin,
            uploadID: UploadID(ClientStoreFixtures.uuid(302)),
            beganAt: first.generationExpiresAt
        )
        try store.persistUploadAttempt(replacement, for: tuple)
        #expect(try store.uploadAttempt(id: first.uploadID)?.attempt.status == .active)
        #expect(try store.uploadAttempt(id: replacement.uploadID)?.attempt == replacement)
        #expect(try store.recordingOutbox(for: origin)?.uploadID == replacement.uploadID)

        let conflictOrigin = ClientStoreFixtures.origin(recording: 2)
        _ = try store.persistFinalizedCapture(
            ClientStoreFixtures.capture(origin: conflictOrigin),
            masterFileURL: root.appendingPathComponent("conflict-master.wav")
        )
        var conflict = ClientStoreFixtures.attempt(
            origin: conflictOrigin,
            uploadID: UploadID(ClientStoreFixtures.uuid(303))
        )
        let conflictingDescriptor = try LogicalChunkDescriptor(
            originRecordingID: conflictOrigin,
            chunkID: ChunkID(ClientStoreFixtures.uuid(201)),
            chunkIndex: 0,
            canonicalStartFrame: 0,
            canonicalFrameCount: 1_000,
            encoding: .cafALAC,
            encodedByteLength: 1_000,
            encodedSHA256: try EncodedChunkSHA256(ClientStoreFixtures.bytes(99)),
            canonicalDecodedByteLength: 2_000,
            canonicalDecodedSHA256: try CanonicalPCMHash(ClientStoreFixtures.bytes(98))
        )
        #expect(throws: TransferValidationError.self) {
            try conflict.declare(
                [conflictingDescriptor],
                generation: .initial,
                at: ClientStoreFixtures.baseDate
            )
        }
        #expect(conflict.status == .conflictBlocked)
        try store.persistUploadAttempt(conflict, for: tuple)
        let rejectedReplacement = ClientStoreFixtures.attempt(
            origin: conflictOrigin,
            uploadID: UploadID(ClientStoreFixtures.uuid(304)),
            beganAt: afterExpiry
        )
        #expect(throws: ClientStoreError.self) {
            try store.persistUploadAttempt(rejectedReplacement, for: tuple)
        }
        #expect(try store.recordingOutbox(for: conflictOrigin)?.uploadID == conflict.uploadID)
        #expect(try store.uploadAttempt(id: rejectedReplacement.uploadID) == nil)
    }

    @Test("a durable supersession proof rejects an older ID after its replacement expires and reopen")
    func expiredReplacementCannotResurrectSupersededAttempt() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = RecordingStorageAttributes()
        let origin = ClientStoreFixtures.origin(recording: 310)
        let tuple = ClientStoreFixtures.tuple(library: 1, authorityByte: 1)
        let first = ClientStoreFixtures.attempt(
            origin: origin,
            uploadID: UploadID(ClientStoreFixtures.uuid(310))
        )
        let replacementTime = first.generationExpiresAt.addingTimeInterval(1)
        let replacement = ClientStoreFixtures.attempt(
            origin: origin,
            uploadID: UploadID(ClientStoreFixtures.uuid(311)),
            beganAt: replacementTime
        )
        let afterReplacementExpiry = replacement.generationExpiresAt.addingTimeInterval(1)

        let store = try HarcTransferStore(
            databaseURL: ClientStoreLocations(rootDirectory: root).transferDatabase,
            installationDeviceID: origin.deviceID,
            storageAttributes: attributes,
            now: { replacementTime }
        )
        _ = try store.adopt(
            ClientStoreFixtures.adoption(
                tuple: tuple,
                keyByte: 1,
                transportEpoch: 1,
                transportByte: 1,
                grantEpoch: 1,
                grantByte: 1
            )
        )
        _ = try store.persistFinalizedCapture(
            ClientStoreFixtures.capture(origin: origin),
            masterFileURL: root.appendingPathComponent("expired-supersession.wav")
        )
        try store.persistUploadAttempt(first, for: tuple)
        try store.persistUploadAttempt(
            replacement,
            for: tuple,
            updatedAt: replacementTime
        )

        let durableReplacement = try store.database.queue.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT replacement_upload_id
                    FROM upload_attempt_supersessions
                    WHERE superseded_upload_id = ?
                    """,
                arguments: [first.uploadID.description]
            )
        }
        #expect(durableReplacement == replacement.uploadID.description)
        let expected = ClientStoreError.uploadAttemptSuperseded(
            uploadID: first.uploadID,
            replacement: replacement.uploadID
        )
        #expect(throws: expected) {
            try store.persistUploadAttempt(
                first,
                for: tuple,
                updatedAt: afterReplacementExpiry
            )
        }

        let reopened = try HarcTransferStore(
            databaseURL: ClientStoreLocations(rootDirectory: root).transferDatabase,
            installationDeviceID: origin.deviceID,
            storageAttributes: attributes,
            now: { afterReplacementExpiry }
        )
        #expect(throws: expected) {
            try reopened.persistUploadAttempt(first, for: tuple)
        }
        #expect(try reopened.recordingOutbox(for: origin)?.uploadID == replacement.uploadID)
    }

    @Test("a durable supersession proof rejects an older ID after its replacement is abandoned and reopen")
    func abandonedReplacementCannotResurrectSupersededAttempt() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = RecordingStorageAttributes()
        let origin = ClientStoreFixtures.origin(recording: 312)
        let tuple = ClientStoreFixtures.tuple(library: 1, authorityByte: 1)
        let first = ClientStoreFixtures.attempt(
            origin: origin,
            uploadID: UploadID(ClientStoreFixtures.uuid(312))
        )
        let replacementTime = first.generationExpiresAt.addingTimeInterval(1)
        var replacement = ClientStoreFixtures.attempt(
            origin: origin,
            uploadID: UploadID(ClientStoreFixtures.uuid(313)),
            beganAt: replacementTime
        )
        let abandonedAt = replacementTime.addingTimeInterval(1)

        let store = try HarcTransferStore(
            databaseURL: ClientStoreLocations(rootDirectory: root).transferDatabase,
            installationDeviceID: origin.deviceID,
            storageAttributes: attributes,
            now: { replacementTime }
        )
        _ = try store.adopt(
            ClientStoreFixtures.adoption(
                tuple: tuple,
                keyByte: 1,
                transportEpoch: 1,
                transportByte: 1,
                grantEpoch: 1,
                grantByte: 1
            )
        )
        _ = try store.persistFinalizedCapture(
            ClientStoreFixtures.capture(origin: origin),
            masterFileURL: root.appendingPathComponent("abandoned-supersession.wav")
        )
        try store.persistUploadAttempt(first, for: tuple)
        try store.persistUploadAttempt(replacement, for: tuple, updatedAt: replacementTime)
        try replacement.abandon(at: abandonedAt)
        try store.persistUploadAttempt(replacement, for: tuple, updatedAt: abandonedAt)

        let expected = ClientStoreError.uploadAttemptSuperseded(
            uploadID: first.uploadID,
            replacement: replacement.uploadID
        )
        #expect(throws: expected) {
            try store.persistUploadAttempt(first, for: tuple, updatedAt: abandonedAt)
        }

        let reopened = try HarcTransferStore(
            databaseURL: ClientStoreLocations(rootDirectory: root).transferDatabase,
            installationDeviceID: origin.deviceID,
            storageAttributes: attributes,
            now: { abandonedAt }
        )
        #expect(throws: expected) {
            try reopened.persistUploadAttempt(first, for: tuple)
        }
        #expect(try reopened.uploadAttempt(id: replacement.uploadID)?.attempt.status == .abandoned)
    }

    @Test("prior-key captures remain local-only and cannot be queued or uploaded after reopen")
    func priorKeyCaptureRemainsLocalOnly() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = RecordingStorageAttributes()
        let oldOrigin = ClientStoreFixtures.origin(deviceByte: 1, recording: 314)
        let currentDevice = ClientStoreFixtures.device(2)
        let tuple = ClientStoreFixtures.tuple(library: 2, authorityByte: 2)
        let expected = ClientStoreError.captureDeviceMismatch(
            expected: currentDevice,
            presented: oldOrigin.deviceID
        )

        do {
            let store = try HarcTransferStore(
                rootDirectory: root,
                installationDeviceID: currentDevice,
                storageAttributes: attributes
            )
            _ = try store.adopt(
                ClientStoreFixtures.adoption(
                    tuple: tuple,
                    keyByte: 2,
                    transportEpoch: 1,
                    transportByte: 2,
                    grantEpoch: 1,
                    grantByte: 2,
                    deviceByte: 2
                )
            )
            _ = try store.persistFinalizedCapture(
                ClientStoreFixtures.capture(origin: oldOrigin),
                masterFileURL: root.appendingPathComponent("prior-key.wav")
            )
            #expect(try store.recordingOutbox(for: oldOrigin)?.stateMachine.state == .localOnly)
            #expect(throws: expected) {
                try store.updateRecordingOutbox(for: oldOrigin) { machine in
                    try machine.queue()
                }
            }
            #expect(throws: expected) {
                try store.persistUploadAttempt(
                    ClientStoreFixtures.attempt(origin: oldOrigin),
                    for: tuple
                )
            }
            #expect(try store.recordingOutbox(for: oldOrigin)?.stateMachine.state == .localOnly)
        }

        let reopened = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: currentDevice,
            storageAttributes: attributes
        )
        #expect(throws: expected) {
            try reopened.updateRecordingOutbox(for: oldOrigin) { machine in
                try machine.queue()
            }
        }
        #expect(throws: expected) {
            try reopened.persistUploadAttempt(
                ClientStoreFixtures.attempt(origin: oldOrigin),
                for: tuple
            )
        }
        #expect(try reopened.recordingOutbox(for: oldOrigin)?.stateMachine.state == .localOnly)
    }

    @Test("replacement installation cannot advance or rebind an already queued prior-key attempt")
    func replacementInstallationCannotAdvanceHistoricalAttempt() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = RecordingStorageAttributes()
        let oldOrigin = ClientStoreFixtures.origin(deviceByte: 1, recording: 315)
        let oldTuple = ClientStoreFixtures.tuple(library: 1, authorityByte: 1)
        let currentTuple = ClientStoreFixtures.tuple(library: 2, authorityByte: 2)
        let first = ClientStoreFixtures.attempt(
            origin: oldOrigin,
            uploadID: UploadID(ClientStoreFixtures.uuid(315))
        )
        let chunk = ClientStoreFixtures.chunk(origin: oldOrigin)

        do {
            let original = try HarcTransferStore(
                rootDirectory: root,
                installationDeviceID: oldOrigin.deviceID,
                storageAttributes: attributes
            )
            _ = try original.adopt(
                ClientStoreFixtures.adoption(
                    tuple: oldTuple,
                    keyByte: 1,
                    transportEpoch: 1,
                    transportByte: 1,
                    grantEpoch: 1,
                    grantByte: 1
                )
            )
            _ = try original.persistFinalizedCapture(
                ClientStoreFixtures.capture(origin: oldOrigin),
                masterFileURL: root.appendingPathComponent("queued-prior-key.wav")
            )
            _ = try original.updateRecordingOutbox(for: oldOrigin) { machine in
                try machine.queue()
                try machine.beginAuthorization()
            }
            try original.persistUploadAttempt(first, for: oldTuple)
            try original.persistEncodedChunk(
                uploadID: first.uploadID,
                descriptor: chunk,
                encodedFileURL: root.appendingPathComponent("queued-prior-key.caf"),
                stateMachine: ChunkOutboxStateMachine()
            )
        }

        let currentDevice = ClientStoreFixtures.device(2)
        let replacementInstallation = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: currentDevice,
            storageAttributes: attributes
        )
        _ = try replacementInstallation.adopt(
            ClientStoreFixtures.adoption(
                tuple: currentTuple,
                keyByte: 2,
                transportEpoch: 1,
                transportByte: 2,
                grantEpoch: 1,
                grantByte: 2,
                deviceByte: 2
            )
        )
        let expected = ClientStoreError.captureDeviceMismatch(
            expected: currentDevice,
            presented: oldOrigin.deviceID
        )
        #expect(throws: expected) {
            try replacementInstallation.updateRecordingOutbox(for: oldOrigin) { machine in
                try machine.beginActiveUpload()
            }
        }
        #expect(throws: expected) {
            try replacementInstallation.updateChunkOutbox(
                uploadID: first.uploadID,
                chunkIndex: chunk.chunkIndex
            ) { machine in
                try machine.beginEncoding()
            }
        }
        var abandoned = first
        try abandoned.abandon(at: ClientStoreFixtures.baseDate.addingTimeInterval(1))
        let replacement = ClientStoreFixtures.attempt(
            origin: oldOrigin,
            uploadID: UploadID(ClientStoreFixtures.uuid(316)),
            beganAt: ClientStoreFixtures.baseDate.addingTimeInterval(2)
        )
        #expect(throws: expected) {
            try replacementInstallation.persistUploadAttempt(
                replacement,
                for: currentTuple,
                abandoning: abandoned,
                updatedAt: ClientStoreFixtures.baseDate.addingTimeInterval(2)
            )
        }
        #expect(try replacementInstallation.recordingOutbox(for: oldOrigin)?.uploadID == first.uploadID)
        #expect(try replacementInstallation.recordingOutbox(for: oldOrigin)?.stateMachine.state == .authorizing)

        let reopened = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: currentDevice,
            storageAttributes: attributes
        )
        #expect(throws: expected) {
            try reopened.updateRecordingOutbox(for: oldOrigin) { machine in
                try machine.beginActiveUpload()
            }
        }
        #expect(throws: expected) {
            try reopened.updateChunkOutbox(
                uploadID: first.uploadID,
                chunkIndex: chunk.chunkIndex
            ) { machine in
                try machine.beginEncoding()
            }
        }
        #expect(try reopened.recordingOutbox(for: oldOrigin)?.stateMachine.state == .authorizing)
    }

    @Test("exact receipt bytes and cleanup intent cannot imply deletion eligibility in PR3")
    func receiptDoesNotEnableCleanup() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: RecordingStorageAttributes()
        )
        let origin = ClientStoreFixtures.origin()
        _ = try store.persistFinalizedCapture(
            ClientStoreFixtures.capture(origin: origin),
            masterFileURL: root.appendingPathComponent("master.wav")
        )
        let receipt = ClientStoreFixtures.exactObject(kind: .recordingReceiptV1, byte: 22)
        try store.persistExactObject(receipt)
        let intent = try store.requestCleanup(for: origin)
        #expect(intent.isEligible == false)
        #expect(try store.exactObject(sha256: receipt.objectSHA256) == receipt)
        #expect(try store.cleanupIntent(for: origin)?.isEligible == false)
        #expect(throws: ClientStoreError.self) {
            try store.makeCleanupEligible(for: origin)
        }

        #expect(throws: DatabaseError.self) {
            try store.database.queue.write { db in
                try db.execute(
                    sql: """
                        UPDATE cleanup_intents
                        SET state = 'eligible', verified_receipt_sha256 = ?
                        WHERE origin_device_id = ? AND origin_recording_uuid = ?
                        """,
                    arguments: [
                        receipt.objectSHA256.rawBytes,
                        origin.deviceID.rawBytes,
                        origin.recordingUUID.uuidString.lowercased(),
                    ]
                )
            }
        }
        #expect(try store.cleanupIntent(for: origin)?.isEligible == false)
    }

    @Test("store refuses committed state without its future verified-receipt transaction")
    func cannotPersistCommittedState() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = try ClientStoreValidatedEvidenceFixture()
        let store = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: evidence.origin.deviceID,
            storageAttributes: RecordingStorageAttributes()
        )
        let tuple = evidence.tuple
        let origin = evidence.origin
        _ = try store.adopt(evidence.adoption)
        _ = try store.persistFinalizedCapture(
            evidence.capture,
            masterFileURL: root.appendingPathComponent("master.wav")
        )
        _ = try store.updateRecordingOutbox(for: origin) { machine in
            try machine.queue()
            try machine.beginAuthorization()
            try machine.beginActiveUpload()
            try machine.awaitHostCommit()
        }
        #expect(throws: ClientStoreError.self) {
            try store.updateRecordingOutbox(for: origin) { machine in
                try machine.markCommitted(
                    using: evidence.receiptEvidence
                )
            }
        }
        #expect(try store.recordingOutbox(for: origin)?.stateMachine.state == .hostCommitPending)

        var attempt = evidence.attempt
        _ = try attempt.bindFinalManifest(
            using: evidence.manifestEvidence,
            generation: .initial,
            at: ClientStoreFixtures.baseDate
        )
        try attempt.markCommitted(
            using: evidence.receiptEvidence,
            generation: .initial,
            at: ClientStoreFixtures.baseDate.addingTimeInterval(1)
        )
        #expect(throws: ClientStoreError.self) {
            try store.persistUploadAttempt(attempt, for: tuple)
        }
        #expect(try store.uploadAttempt(id: attempt.uploadID) == nil)
    }

    @Test("exact object hash equivocation rolls back")
    func exactObjectEquivocation() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: ClientStoreFixtures.device(),
            storageAttributes: RecordingStorageAttributes()
        )
        let first = ClientStoreFixtures.exactObject(kind: .audioBatchAckV1, byte: 30)
        let conflicting = try OpaqueExactObjectSlot(
            kind: .audioBatchAckV1,
            exactBytes: Data([0xFF]),
            objectSHA256: first.objectSHA256
        )
        try store.persistExactObject(first)
        #expect(throws: ClientStoreError.self) {
            try store.persistExactObject(conflicting)
        }
        #expect(try store.exactObject(sha256: first.objectSHA256) == first)

        let conflict = try TransferConflictRecord(
            originRecordingID: ClientStoreFixtures.origin(),
            uploadID: UploadID(ClientStoreFixtures.uuid(300)),
            code: "exact-object-conflict",
            localExactBytes: first.exactBytes,
            remoteExactBytes: conflicting.exactBytes,
            createdAt: ClientStoreFixtures.baseDate
        )
        try store.recordTransferConflict(conflict)
        try store.recordTransferConflict(conflict)
        #expect(try store.transferConflicts() == [conflict])
    }

    @Test("host reconciliation persists exact receipt but waits for future validation")
    func hostReconciliationDoesNotCommit() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = RecordingStorageAttributes()
        let evidence = try ClientStoreValidatedEvidenceFixture(
            manifestByte: 40,
            receiptByte: 41
        )
        let tuple = evidence.tuple
        let origin = evidence.origin
        let capture = evidence.capture
        let chunk = evidence.chunk
        var attempt = evidence.attempt
        let manifest = evidence.manifestEvidence.exactManifestObject
        _ = try attempt.bindFinalManifest(
            using: evidence.manifestEvidence,
            generation: .initial,
            at: ClientStoreFixtures.baseDate
        )
        let receipt = evidence.receiptEvidence.exactReceiptObject

        do {
            let store = try HarcTransferStore(
                rootDirectory: root,
                installationDeviceID: origin.deviceID,
                storageAttributes: attributes
            )
            _ = try store.adopt(evidence.adoption)
            _ = try store.persistFinalizedCapture(
                capture,
                masterFileURL: root.appendingPathComponent("master.wav")
            )
            _ = try store.updateRecordingOutbox(for: origin) { machine in
                try machine.queue()
                try machine.beginAuthorization()
                try machine.beginActiveUpload()
                try machine.awaitHostCommit()
            }
            try store.persistUploadAttempt(attempt, for: tuple)
            var chunkMachine = ChunkOutboxStateMachine()
            try chunkMachine.beginEncoding()
            try chunkMachine.markReady()
            try chunkMachine.schedule()
            try store.persistEncodedChunk(
                uploadID: attempt.uploadID,
                descriptor: chunk,
                encodedFileURL: root.appendingPathComponent("chunk.caf"),
                stateMachine: chunkMachine
            )
            let reconciliation = try UploadReconciliation(
                uploadID: attempt.uploadID,
                ownerDeviceID: origin.deviceID,
                originRecordingID: origin,
                uploadProfileSHA256: attempt.frozenProfile.profileSHA256,
                generation: attempt.generation,
                firstBeganAt: attempt.firstBeganAt,
                generationBeganAt: attempt.generationBeganAt,
                generationExpiresAt: attempt.generationExpiresAt,
                declarations: [chunk],
                boundManifestObjectSHA256: manifest.objectSHA256,
                durableChunks: [
                    DurableChunkStatus(
                        chunkIndex: chunk.chunkIndex,
                        chunkID: chunk.chunkID,
                        encodedSHA256: chunk.encodedSHA256
                    ),
                ],
                rejectedChunks: [],
                terminalReason: .committed,
                existingReceipt: receipt
            )
            try store.applyUploadReconciliation(reconciliation)
            #expect(try store.chunks(uploadID: attempt.uploadID)[0].stateMachine.state == .durableAtHost)
            #expect(try store.exactObject(sha256: receipt.objectSHA256) == receipt)
            #expect(try store.recordingOutbox(for: origin)?.stateMachine.state == .hostCommitPending)
            #expect(try store.cleanupIntent(for: origin) == nil)
        }

        let reopened = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: origin.deviceID,
            storageAttributes: attributes
        )
        #expect(try reopened.lastUploadReconciliation(uploadID: attempt.uploadID)?.existingReceipt == receipt)
        #expect(try reopened.recordingOutbox(for: origin)?.stateMachine.state == .hostCommitPending)
    }

    @Test("missing immutable bytes quarantine the recording until exact restoration")
    func immutableArtifactIntegrityBlock() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = RecordingStorageAttributes()
        let origin = ClientStoreFixtures.origin()
        let tuple = ClientStoreFixtures.tuple(library: 1, authorityByte: 1)
        let attempt = ClientStoreFixtures.attempt(origin: origin)
        let chunk = ClientStoreFixtures.chunk(origin: origin)
        let batch = ClientStoreFixtures.batch(origin: origin, uploadID: attempt.uploadID)
        let masterURL = root.appendingPathComponent("master.wav")
        let chunkURL = root.appendingPathComponent("chunk.caf")
        let batchURL = root.appendingPathComponent("batch.bin")
        let store = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: origin.deviceID,
            storageAttributes: attributes
        )
        _ = try store.adopt(
            ClientStoreFixtures.adoption(
                tuple: tuple,
                keyByte: 1,
                transportEpoch: 1,
                transportByte: 1,
                grantEpoch: 1,
                grantByte: 1
            )
        )
        _ = try store.persistFinalizedCapture(
            ClientStoreFixtures.capture(origin: origin),
            masterFileURL: masterURL
        )
        _ = try store.updateRecordingOutbox(for: origin) { machine in
            try machine.queue()
            try machine.beginAuthorization()
            try machine.beginActiveUpload()
        }
        try store.persistUploadAttempt(attempt, for: tuple)
        var chunkMachine = ChunkOutboxStateMachine()
        try chunkMachine.beginEncoding()
        try chunkMachine.markReady()
        try chunkMachine.schedule()
        try store.persistEncodedChunk(
            uploadID: attempt.uploadID,
            descriptor: chunk,
            encodedFileURL: chunkURL,
            stateMachine: chunkMachine
        )
        try store.persistBackgroundBatch(
            batch,
            bodyFileURL: batchURL,
            capability: OpaqueBackgroundCapability(
                credential: Data([1]),
                capabilityBindings: Data([2]),
                expiresAt: ClientStoreFixtures.baseDate.addingTimeInterval(300)
            )
        )
        let ack = ClientStoreFixtures.exactObject(kind: .audioBatchAckV1, byte: 60)
        try store.persistVerifiedBatchACK(
            ack,
            batchID: batch.batchID,
            durableChunks: [
                DurableChunkStatus(
                    chunkIndex: chunk.chunkIndex,
                    chunkID: chunk.chunkID,
                    encodedSHA256: chunk.encodedSHA256
                ),
            ]
        )

        let missing = try store.reconcileLocalArtifacts(
            inspector: StubArtifactInspector(existingURLs: [masterURL])
        )
        #expect(missing.missingChunks == [chunk.chunkID])
        #expect(missing.missingBatches == [batch.batchID])
        let blocked = try #require(try store.recordingOutbox(for: origin))
        #expect(blocked.stateMachine.state == .securityBlocked)
        #expect(blocked.integrityBlock != nil)
        #expect(try store.chunks(uploadID: attempt.uploadID)[0].stateMachine.state == .durableAtHost)
        #expect(try store.chunks(uploadID: attempt.uploadID)[0].durableACK == ack)
        #expect(try store.backgroundBatch(id: batch.batchID)?.state == .completed)
        #expect(try store.backgroundBatch(id: batch.batchID)?.durableACK == ack)
        #expect(throws: ClientStoreError.self) {
            try store.updateRecordingOutbox(for: origin) { machine in
                try machine.resumeAfterUserSecurityAction()
            }
        }
        #expect(throws: ClientStoreError.self) {
            try store.updateChunkOutbox(
                uploadID: attempt.uploadID,
                chunkIndex: chunk.chunkIndex
            ) { _ in }
        }

        let reopened = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: origin.deviceID,
            storageAttributes: attributes
        )
        #expect(try reopened.recordingOutbox(for: origin)?.integrityBlock != nil)
        #expect(try reopened.chunks(uploadID: attempt.uploadID)[0].durableACK == ack)

        let mismatch = try reopened.reconcileLocalArtifacts(
            inspector: StubArtifactInspector(
                existingURLs: [masterURL, chunkURL, batchURL],
                mismatchedURLs: [chunkURL, batchURL]
            )
        )
        #expect(mismatch.missingChunks.isEmpty)
        #expect(mismatch.missingBatches.isEmpty)
        #expect(mismatch.mismatchedChunks == [chunk.chunkID])
        #expect(mismatch.mismatchedBatches == [batch.batchID])
        #expect(try reopened.recordingOutbox(for: origin)?.integrityBlock != nil)

        let restored = try reopened.reconcileLocalArtifacts(
            inspector: StubArtifactInspector(
                existingURLs: [masterURL, chunkURL, batchURL]
            )
        )
        #expect(restored.missingChunks.isEmpty)
        #expect(restored.mismatchedChunks.isEmpty)
        #expect(try reopened.recordingOutbox(for: origin)?.integrityBlock == nil)
        // Exact restoration clears the durable store guard, while the
        // security state still requires explicit user-controlled resumption.
        #expect(try reopened.recordingOutbox(for: origin)?.stateMachine.state == .securityBlocked)
        _ = try reopened.updateRecordingOutbox(for: origin) { machine in
            try machine.resumeAfterUserSecurityAction()
        }
        #expect(try reopened.recordingOutbox(for: origin)?.stateMachine.state == .queued)
        #expect(try reopened.chunks(uploadID: attempt.uploadID)[0].durableACK == ack)

        _ = try reopened.reconcileLocalArtifacts(
            inspector: StubArtifactInspector(existingURLs: [masterURL])
        )
        var abandoned = attempt
        try abandoned.abandon(at: ClientStoreFixtures.baseDate.addingTimeInterval(20))
        let replacement = ClientStoreFixtures.attempt(
            origin: origin,
            uploadID: UploadID(ClientStoreFixtures.uuid(306)),
            beganAt: ClientStoreFixtures.baseDate.addingTimeInterval(21)
        )
        try reopened.persistUploadAttempt(
            replacement,
            for: tuple,
            abandoning: abandoned,
            updatedAt: ClientStoreFixtures.baseDate.addingTimeInterval(21)
        )
        #expect(try reopened.recordingOutbox(for: origin)?.integrityBlock == nil)
        #expect(try reopened.recordingOutbox(for: origin)?.uploadID == replacement.uploadID)
        #expect(try reopened.uploadAttempt(id: attempt.uploadID)?.attempt.status == .abandoned)
        #expect(try reopened.chunks(uploadID: attempt.uploadID)[0].durableACK == ack)
    }

    @Test("reopen persistence cannot erase immutable upload declarations")
    func uploadProgressCannotRollBack() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = ClientStoreFixtures.origin()
        let store = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: origin.deviceID,
            storageAttributes: RecordingStorageAttributes()
        )
        let tuple = ClientStoreFixtures.tuple(library: 1, authorityByte: 1)
        _ = try store.adopt(
            ClientStoreFixtures.adoption(
                tuple: tuple,
                keyByte: 1,
                transportEpoch: 1,
                transportByte: 1,
                grantEpoch: 1,
                grantByte: 1
            )
        )
        _ = try store.persistFinalizedCapture(
            ClientStoreFixtures.capture(origin: origin),
            masterFileURL: root.appendingPathComponent("master.wav")
        )
        let persisted = ClientStoreFixtures.attempt(origin: origin)
        try store.persistUploadAttempt(persisted, for: tuple)
        let regressed = try UploadAttempt(
            uploadID: persisted.uploadID,
            ownerDeviceID: origin.deviceID,
            originRecordingID: origin,
            frozenProfile: persisted.frozenProfile,
            beganAt: persisted.firstBeganAt
        )
        #expect(throws: ClientStoreError.self) {
            try store.persistUploadAttempt(regressed, for: tuple)
        }
        #expect(try store.uploadAttempt(id: persisted.uploadID)?.attempt.declarations.descriptors.count == 1)
    }

    @Test("exact batch ACK records staging durability without recording commit")
    func batchACKIsNotReceipt() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = ClientStoreFixtures.origin()
        let store = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: origin.deviceID,
            storageAttributes: RecordingStorageAttributes()
        )
        let tuple = ClientStoreFixtures.tuple(library: 1, authorityByte: 1)
        let attempt = ClientStoreFixtures.attempt(origin: origin)
        let chunk = ClientStoreFixtures.chunk(origin: origin)
        let batch = ClientStoreFixtures.batch(origin: origin, uploadID: attempt.uploadID)
        _ = try store.adopt(
            ClientStoreFixtures.adoption(
                tuple: tuple,
                keyByte: 1,
                transportEpoch: 1,
                transportByte: 1,
                grantEpoch: 1,
                grantByte: 1
            )
        )
        _ = try store.persistFinalizedCapture(
            ClientStoreFixtures.capture(origin: origin),
            masterFileURL: root.appendingPathComponent("master.wav")
        )
        try store.persistUploadAttempt(attempt, for: tuple)
        var chunkMachine = ChunkOutboxStateMachine()
        try chunkMachine.beginEncoding()
        try chunkMachine.markReady()
        try chunkMachine.schedule()
        try store.persistEncodedChunk(
            uploadID: attempt.uploadID,
            descriptor: chunk,
            encodedFileURL: root.appendingPathComponent("chunk.caf"),
            stateMachine: chunkMachine
        )
        try store.persistBackgroundBatch(
            batch,
            bodyFileURL: root.appendingPathComponent("batch.bin"),
            capability: OpaqueBackgroundCapability(
                credential: Data([1]),
                capabilityBindings: Data([2]),
                expiresAt: ClientStoreFixtures.baseDate.addingTimeInterval(300)
            )
        )
        let taskIdentity = try SystemBackgroundTaskIdentity(
            taskIdentifier: 50
        )
        try store.persistTaskMappingBeforeResume(
            taskIdentity,
            batchID: batch.batchID
        )
        #expect(
            try store.backgroundBatch(id: batch.batchID)?.state == .scheduled
        )
        let ack = ClientStoreFixtures.exactObject(kind: .audioBatchAckV1, byte: 50)
        let durable = [
            DurableChunkStatus(
                chunkIndex: chunk.chunkIndex,
                chunkID: chunk.chunkID,
                encodedSHA256: chunk.encodedSHA256
            ),
        ]
        try store.persistVerifiedBatchACK(ack, batchID: batch.batchID, durableChunks: durable)
        try store.persistVerifiedBatchACK(ack, batchID: batch.batchID, durableChunks: durable)

        #expect(try store.backgroundBatch(id: batch.batchID)?.durableACK == ack)
        #expect(try store.backgroundBatch(id: batch.batchID)?.state == .completed)
        #expect(try store.taskMappings().map(\.state) == [.completed])
        try store.persistTaskMappingBeforeResume(
            taskIdentity,
            batchID: batch.batchID
        )
        #expect(try store.taskMappings().map(\.state) == [.completed])
        #expect(throws: ClientStoreError.self) {
            try store.persistTaskMappingBeforeResume(
                SystemBackgroundTaskIdentity(taskIdentifier: 51),
                batchID: batch.batchID
            )
        }
        #expect(try store.chunks(uploadID: attempt.uploadID)[0].durableACK == ack)
        #expect(try store.chunks(uploadID: attempt.uploadID)[0].stateMachine.state == .durableAtHost)
        #expect(try store.recordingOutbox(for: origin)?.stateMachine.state == .localOnly)
        #expect(try store.cleanupIntent(for: origin) == nil)
    }

    @Test("background task failures are durable and security-monotonic")
    func backgroundTaskFailurePersistence() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = ClientStoreFixtures.origin()
        let tuple = ClientStoreFixtures.tuple(library: 1, authorityByte: 1)
        let attempt = ClientStoreFixtures.attempt(origin: origin)
        let batch = ClientStoreFixtures.batch(
            origin: origin,
            uploadID: attempt.uploadID
        )
        let store = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: origin.deviceID,
            storageAttributes: RecordingStorageAttributes()
        )
        _ = try store.adopt(
            ClientStoreFixtures.adoption(
                tuple: tuple,
                keyByte: 1,
                transportEpoch: 1,
                transportByte: 1,
                grantEpoch: 1,
                grantByte: 1
            )
        )
        _ = try store.persistFinalizedCapture(
            ClientStoreFixtures.capture(origin: origin),
            masterFileURL: root.appendingPathComponent("master.wav")
        )
        try store.persistUploadAttempt(attempt, for: tuple)
        let batchURL = root.appendingPathComponent("batch.harcab1")
        try store.persistBackgroundBatch(
            batch,
            bodyFileURL: batchURL,
            capability: OpaqueBackgroundCapability(
                credential: Data([1]),
                capabilityBindings: Data([2]),
                expiresAt: ClientStoreFixtures.baseDate
                    .addingTimeInterval(300)
            )
        )
        let identity = try SystemBackgroundTaskIdentity(taskIdentifier: 71)
        try store.persistTaskMappingBeforeResume(
            identity,
            batchID: batch.batchID
        )

        let replacementCapability = try OpaqueBackgroundCapability(
            credential: Data([3]),
            capabilityBindings: Data([4]),
            expiresAt: ClientStoreFixtures.baseDate.addingTimeInterval(600)
        )
        #expect(throws: ClientStoreError.self) {
            try store.persistBackgroundBatchForScheduling(
                batch,
                bodyFileURL: batchURL,
                capability: replacementCapability
            )
        }

        try store.persistBackgroundTaskFailure(
            identity,
            batchID: batch.batchID,
            disposition: .failedRecoverable
        )
        #expect(
            try store.backgroundBatch(id: batch.batchID)?.state
                == .failedRecoverable
        )
        #expect(try store.taskMappings().map(\.state) == [
            .failedRecoverable,
        ])
        #expect(
            try store.recordingOutbox(for: origin)?.stateMachine.state
                == .failedRecoverable
        )

        try store.persistBackgroundBatchForScheduling(
            batch,
            bodyFileURL: batchURL,
            capability: replacementCapability
        )
        #expect(try store.backgroundBatch(id: batch.batchID)?.capability
            == replacementCapability)
        #expect(try store.backgroundBatch(id: batch.batchID)?.state
            == .readyToSchedule)

        try store.persistBackgroundTaskFailure(
            identity,
            batchID: batch.batchID,
            disposition: .securityBlocked
        )
        try store.persistBackgroundTaskFailure(
            identity,
            batchID: batch.batchID,
            disposition: .failedRecoverable
        )
        #expect(
            try store.backgroundBatch(id: batch.batchID)?.state
                == .securityBlocked
        )
        #expect(try store.taskMappings().map(\.state) == [
            .securityBlocked,
        ])
        #expect(
            try store.recordingOutbox(for: origin)?.stateMachine.state
                == .securityBlocked
        )
        let blockedReconciliation = try store.reconcileBackgroundTasks(
            observedSystemTasks: []
        )
        #expect(blockedReconciliation.batchesToReschedule.isEmpty)
        #expect(try store.taskMappings().map(\.state) == [
            .securityBlocked,
        ])
        #expect(throws: ClientStoreError.self) {
            try store.persistBackgroundTaskFailure(
                identity,
                batchID: AudioBatchID.random(),
                disposition: .failedRecoverable
            )
        }

        let reopened = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: origin.deviceID,
            storageAttributes: RecordingStorageAttributes()
        )
        #expect(
            try reopened.backgroundBatch(id: batch.batchID)?.state
                == .securityBlocked
        )
        #expect(try reopened.taskMappings().map(\.state) == [
            .securityBlocked,
        ])
        #expect(
            try reopened.recordingOutbox(for: origin)?.stateMachine.state
                == .securityBlocked
        )
        #expect(
            try reopened.resumeSecurityBlockedBackgroundUpload(for: origin)
        )
        #expect(
            try reopened.recordingOutbox(for: origin)?.stateMachine.state
                == .queued
        )
        #expect(
            try reopened.backgroundBatch(id: batch.batchID)?.state
                == .failedRecoverable
        )
        #expect(try reopened.taskMappings().map(\.state) == [
            .failedRecoverable,
        ])
        #expect(
            try !reopened.resumeSecurityBlockedBackgroundUpload(for: origin)
        )
    }
}
