import Foundation
import HarcDomain
import Testing
@testable import HarcTransfer

@Suite("HarcTransfer upload attempts and outboxes")
struct UploadAttemptAndOutboxTests {
    @Test("Upload generation has fixed expiry, checks stale callers, and reopens without mutation")
    func expiryAndReopen() throws {
        let origin = TransferFixtures.origin()
        let began = TransferFixtures.baseDate
        var attempt = try UploadAttempt(
            uploadID: .random(),
            ownerDeviceID: origin.deviceID,
            originRecordingID: origin,
            frozenProfile: TransferFixtures.profile(),
            beganAt: began
        )
        let expectedExpiry = began.addingTimeInterval(TransferLimits.uploadGenerationLifetime)
        #expect(attempt.generationExpiresAt == expectedExpiry)
        #expect(try attempt.leaseState(at: expectedExpiry.addingTimeInterval(-1)) == .active)
        #expect(try attempt.leaseState(at: expectedExpiry) == .expired)
        #expect(throws: TransferValidationError.self) {
            try attempt.reopen(at: expectedExpiry.addingTimeInterval(-1))
        }

        let finalized = TransferFixtures.chunkedCapture(origin: origin)
        _ = try attempt.declare(
            finalized.chunks,
            generation: .initial,
            at: began.addingTimeInterval(1)
        )
        let manifest = TransferFixtures.manifestEvidence(
            uploadID: attempt.uploadID,
            finalizedCapture: finalized
        )
        _ = try attempt.bindFinalManifest(
            using: manifest,
            generation: .initial,
            at: began.addingTimeInterval(2)
        )

        try attempt.reopen(at: expectedExpiry)
        #expect(attempt.generation.rawValue == 2)
        #expect(attempt.generationBeganAt == expectedExpiry)
        #expect(attempt.generationExpiresAt == expectedExpiry.addingTimeInterval(TransferLimits.uploadGenerationLifetime))
        #expect(attempt.declarations.descriptors == finalized.chunks)
        #expect(attempt.boundManifest == manifest.exactManifestObject)
        #expect(attempt.boundHostTrust == manifest.hostTrust)
        #expect(throws: TransferValidationError.self) {
            try attempt.requireActive(generation: .initial, at: expectedExpiry.addingTimeInterval(1))
        }
        #expect(try attempt.leaseState(at: expectedExpiry.addingTimeInterval(1)) == .active)

        let data = try JSONEncoder().encode(attempt)
        #expect(try JSONDecoder().decode(UploadAttempt.self, from: data) == attempt)
    }

    @Test("Grant expiry shortens but cannot extend a generation lease")
    func grantExpiryShortensLease() throws {
        let origin = TransferFixtures.origin()
        let began = TransferFixtures.baseDate
        let grantExpiry = began.addingTimeInterval(60)
        let attempt = try UploadAttempt(
            uploadID: .random(),
            ownerDeviceID: origin.deviceID,
            originRecordingID: origin,
            frozenProfile: TransferFixtures.profile(),
            beganAt: began,
            grantExpiresAt: grantExpiry
        )
        #expect(attempt.generationExpiresAt == grantExpiry)
        #expect(throws: TransferValidationError.self) {
            try UploadAttempt(
                uploadID: .random(),
                ownerDeviceID: origin.deviceID,
                originRecordingID: origin,
                frozenProfile: TransferFixtures.profile(),
                beganAt: began,
                grantExpiresAt: began
            )
        }
    }

    @Test("Declaration and manifest conflicts block an attempt until explicit abandon")
    func conflictsAndAbandon() throws {
        let origin = TransferFixtures.origin()
        let began = TransferFixtures.baseDate
        var declarationAttempt = try UploadAttempt(
            uploadID: .random(),
            ownerDeviceID: origin.deviceID,
            originRecordingID: origin,
            frozenProfile: TransferFixtures.profile(),
            beganAt: began
        )
        let first = TransferFixtures.chunk(origin: origin, index: 0, startFrame: 0, frameCount: 10)
        _ = try declarationAttempt.declare([first], generation: .initial, at: began)
        let conflict = TransferFixtures.chunk(
            origin: origin,
            index: 0,
            startFrame: 0,
            frameCount: 9,
            id: 999
        )
        #expect(throws: TransferValidationError.self) {
            try declarationAttempt.declare([conflict], generation: .initial, at: began)
        }
        #expect(declarationAttempt.status == .conflictBlocked)
        #expect(declarationAttempt.blockReason == .chunkDeclarationConflict)
        #expect(throws: TransferValidationError.self) {
            try declarationAttempt.reopen(at: began.addingTimeInterval(TransferLimits.uploadGenerationLifetime))
        }
        #expect(
            try UploadAttemptAdmission.decide(
                proposedUploadID: declarationAttempt.uploadID,
                ownerDeviceID: origin.deviceID,
                originRecordingID: origin,
                frozenProfile: TransferFixtures.profile(),
                existingAttempts: [declarationAttempt],
                at: began.addingTimeInterval(5)
            ) == .conflictBlocked(declarationAttempt.uploadID, .chunkDeclarationConflict)
        )
        try declarationAttempt.abandon(at: began.addingTimeInterval(10))
        let terminalTime = declarationAttempt.terminalAt
        try declarationAttempt.abandon(at: began.addingTimeInterval(20))
        #expect(declarationAttempt.terminalAt == terminalTime)
        #expect(
            try UploadAttemptAdmission.decide(
                proposedUploadID: declarationAttempt.uploadID,
                ownerDeviceID: origin.deviceID,
                originRecordingID: origin,
                frozenProfile: TransferFixtures.profile(),
                existingAttempts: [declarationAttempt],
                at: began.addingTimeInterval(20)
            ) == .abandoned(declarationAttempt.uploadID)
        )

        let finalized = TransferFixtures.chunkedCapture(origin: origin)
        var manifestAttempt = try UploadAttempt(
            uploadID: .random(),
            ownerDeviceID: origin.deviceID,
            originRecordingID: origin,
            frozenProfile: TransferFixtures.profile(),
            beganAt: began
        )
        _ = try manifestAttempt.declare(finalized.chunks, generation: .initial, at: began)
        let firstManifest = TransferFixtures.manifestEvidence(
            uploadID: manifestAttempt.uploadID,
            finalizedCapture: finalized,
            manifestByte: 1
        )
        _ = try manifestAttempt.bindFinalManifest(
            using: firstManifest,
            generation: .initial,
            at: began
        )
        #expect(throws: TransferValidationError.self) {
            try manifestAttempt.bindFinalManifest(
                using: TransferFixtures.manifestEvidence(
                    uploadID: manifestAttempt.uploadID,
                    finalizedCapture: finalized,
                    manifestByte: 2
                ),
                generation: .initial,
                at: began
            )
        }
        #expect(manifestAttempt.status == .conflictBlocked)
        #expect(manifestAttempt.blockReason == .manifestObjectConflict)
    }

    @Test("Commit requires a bound manifest and concrete validator evidence")
    func commitRequiresEvidence() throws {
        let origin = TransferFixtures.origin()
        let began = TransferFixtures.baseDate
        let finalized = TransferFixtures.chunkedCapture(origin: origin)
        var attempt = try UploadAttempt(
            uploadID: .random(),
            ownerDeviceID: origin.deviceID,
            originRecordingID: origin,
            frozenProfile: TransferFixtures.profile(),
            beganAt: began
        )
        let manifest = TransferFixtures.manifestEvidence(
            uploadID: attempt.uploadID,
            finalizedCapture: finalized,
            manifestByte: 6
        )
        let evidence = TransferFixtures.receiptEvidence(manifest: manifest, receiptByte: 7)
        #expect(throws: TransferValidationError.self) {
            try attempt.markCommitted(using: evidence, generation: .initial, at: began)
        }
        _ = try attempt.declare(finalized.chunks, generation: .initial, at: began)
        _ = try attempt.bindFinalManifest(
            using: manifest,
            generation: .initial,
            at: began
        )
        try attempt.markCommitted(using: evidence, generation: .initial, at: began.addingTimeInterval(1))
        #expect(attempt.status == .committed)
        #expect(attempt.exactReceipt == evidence.exactReceiptObject)
        #expect(throws: TransferValidationError.self) {
            try attempt.abandon(at: began.addingTimeInterval(2))
        }
    }

    @Test("validated manifest and receipt evidence bind host, upload, origin, manifest, audio, and profile")
    func validatedEvidenceBindings() throws {
        let began = TransferFixtures.baseDate
        let origin = TransferFixtures.origin()
        let finalized = TransferFixtures.chunkedCapture(origin: origin)
        let profile = TransferFixtures.profile()
        var attempt = try UploadAttempt(
            uploadID: .random(),
            ownerDeviceID: origin.deviceID,
            originRecordingID: origin,
            frozenProfile: profile,
            beganAt: began
        )
        _ = try attempt.declare(finalized.chunks, generation: .initial, at: began)

        let wrongUpload = TransferFixtures.manifestEvidence(
            uploadID: .random(),
            finalizedCapture: finalized,
            profile: profile
        )
        #expect(throws: TransferValidationError.evidenceBindingMismatch(field: "uploadID")) {
            try attempt.bindFinalManifest(using: wrongUpload, generation: .initial, at: began)
        }

        let wrongProfile = TransferFixtures.manifestEvidence(
            uploadID: attempt.uploadID,
            finalizedCapture: finalized,
            profile: TransferFixtures.profile(hashByte: 99)
        )
        #expect(throws: TransferValidationError.evidenceBindingMismatch(field: "uploadProfileSHA256")) {
            try attempt.bindFinalManifest(using: wrongProfile, generation: .initial, at: began)
        }

        let manifest = TransferFixtures.manifestEvidence(
            uploadID: attempt.uploadID,
            finalizedCapture: finalized,
            profile: profile
        )
        _ = try attempt.bindFinalManifest(using: manifest, generation: .initial, at: began)

        #expect(throws: TransferValidationError.evidenceBindingMismatch(field: "hostTrust")) {
            try TransferFixtures.makeReceiptEvidence(
                manifest: manifest,
                hostTrust: TransferFixtures.hostTrust(library: 701, authorityKeyByte: 201)
            )
        }
        #expect(throws: TransferValidationError.evidenceBindingMismatch(field: "uploadID")) {
            try TransferFixtures.makeReceiptEvidence(manifest: manifest, uploadID: .random())
        }
        #expect(throws: TransferValidationError.evidenceBindingMismatch(field: "originRecordingID")) {
            try TransferFixtures.makeReceiptEvidence(
                manifest: manifest,
                originRecordingID: TransferFixtures.origin(deviceByte: 2)
            )
        }
        #expect(throws: TransferValidationError.evidenceBindingMismatch(field: "signedManifestObjectSHA256")) {
            try TransferFixtures.makeReceiptEvidence(
                manifest: manifest,
                signedManifestObjectSHA256: ExactObjectSHA256(TransferFixtures.bytes(77))
            )
        }
        #expect(throws: TransferValidationError.evidenceBindingMismatch(field: "canonicalPCMSHA256")) {
            try TransferFixtures.makeReceiptEvidence(
                manifest: manifest,
                canonicalPCMSHA256: CanonicalPCMHash(TransferFixtures.bytes(78))
            )
        }
        #expect(throws: TransferValidationError.evidenceBindingMismatch(field: "totalCanonicalFrames")) {
            try TransferFixtures.makeReceiptEvidence(
                manifest: manifest,
                totalCanonicalFrames: manifest.totalCanonicalFrames + 1
            )
        }
        #expect(throws: TransferValidationError.evidenceBindingMismatch(field: "canonicalFormat")) {
            try TransferFixtures.makeReceiptEvidence(
                manifest: manifest,
                canonicalFormat: CanonicalPCMFormat(
                    sampleRateHz: 48_000,
                    channelCount: 1,
                    encoding: .signedInt16LittleEndian
                )
            )
        }

        let receipt = TransferFixtures.receiptEvidence(manifest: manifest)
        #expect(receipt.uploadProfileSHA256 == profile.profileSHA256)
        try attempt.markCommitted(
            using: receipt,
            generation: .initial,
            at: began.addingTimeInterval(1)
        )
        #expect(attempt.status == .committed)
    }

    @Test("Admission enforces replay, one origin attempt, expiry, and four active sessions")
    func admissionAndQuota() throws {
        let owner = TransferFixtures.device()
        let now = TransferFixtures.baseDate
        let profile = TransferFixtures.profile()
        let origin = TransferFixtures.origin(recording: 1)
        let uploadID = UploadID.random()
        let active = try UploadAttempt(
            uploadID: uploadID,
            ownerDeviceID: owner,
            originRecordingID: origin,
            frozenProfile: profile,
            beganAt: now
        )
        #expect(
            try UploadAttemptAdmission.decide(
                proposedUploadID: uploadID,
                ownerDeviceID: owner,
                originRecordingID: origin,
                frozenProfile: profile,
                existingAttempts: [active],
                at: now
            ) == .exactReplay(uploadID)
        )
        #expect(throws: TransferValidationError.self) {
            try UploadAttemptAdmission.decide(
                proposedUploadID: .random(),
                ownerDeviceID: owner,
                originRecordingID: origin,
                frozenProfile: profile,
                existingAttempts: [active],
                at: now
            )
        }
        #expect(
            try UploadAttemptAdmission.decide(
                proposedUploadID: uploadID,
                ownerDeviceID: owner,
                originRecordingID: origin,
                frozenProfile: profile,
                existingAttempts: [active],
                at: now.addingTimeInterval(TransferLimits.uploadGenerationLifetime)
            ) == .reopenRequired(uploadID)
        )

        let four = try (1...4).map { value in
            try UploadAttempt(
                uploadID: .random(),
                ownerDeviceID: owner,
                originRecordingID: TransferFixtures.origin(recording: UInt32(value)),
                frozenProfile: profile,
                beganAt: now
            )
        }
        #expect(throws: TransferValidationError.self) {
            try UploadAttemptAdmission.decide(
                proposedUploadID: .random(),
                ownerDeviceID: owner,
                originRecordingID: TransferFixtures.origin(recording: 99),
                frozenProfile: profile,
                existingAttempts: four,
                at: now
            )
        }
    }

    @Test("Admission checks every origin owner and global capacity before reopening an expired ID")
    func admissionReopenCannotBypassOriginOrCapacity() throws {
        let owner = TransferFixtures.device()
        let began = TransferFixtures.baseDate
        let evaluatedAt = began.addingTimeInterval(
            TransferLimits.uploadGenerationLifetime + 10
        )
        let profile = TransferFixtures.profile()
        let origin = TransferFixtures.origin(recording: 700)
        let expiredID = UploadID.random()
        let expired = try UploadAttempt(
            uploadID: expiredID,
            ownerDeviceID: owner,
            originRecordingID: origin,
            frozenProfile: profile,
            beganAt: began
        )
        let currentOwner = try UploadAttempt(
            uploadID: .random(),
            ownerDeviceID: owner,
            originRecordingID: origin,
            frozenProfile: profile,
            beganAt: evaluatedAt.addingTimeInterval(-1)
        )
        #expect(throws: TransferValidationError.invalidUploadAttempt(
            reason: "Upload ID was permanently superseded by a newer attempt for this origin recording."
        )) {
            try UploadAttemptAdmission.decide(
                proposedUploadID: expiredID,
                ownerDeviceID: owner,
                originRecordingID: origin,
                frozenProfile: profile,
                existingAttempts: [expired, currentOwner],
                at: evaluatedAt
            )
        }

        var active = try (1 ... TransferLimits.activeUploadAttemptsPerDevice).map { value in
            try UploadAttempt(
                uploadID: .random(),
                ownerDeviceID: owner,
                originRecordingID: TransferFixtures.origin(recording: UInt32(700 + value)),
                frozenProfile: profile,
                beganAt: evaluatedAt.addingTimeInterval(-1)
            )
        }
        #expect(throws: TransferValidationError.exceedsLimit(
            field: "active upload attempts per device",
            limit: UInt64(TransferLimits.activeUploadAttemptsPerDevice),
            actual: UInt64(TransferLimits.activeUploadAttemptsPerDevice + 1)
        )) {
            try UploadAttemptAdmission.decide(
                proposedUploadID: expiredID,
                ownerDeviceID: owner,
                originRecordingID: origin,
                frozenProfile: profile,
                existingAttempts: [expired] + active,
                at: evaluatedAt
            )
        }
        try active[0].abandon(at: evaluatedAt)
        #expect(
            try UploadAttemptAdmission.decide(
                proposedUploadID: expiredID,
                ownerDeviceID: owner,
                originRecordingID: origin,
                frozenProfile: profile,
                existingAttempts: [expired] + active,
                at: evaluatedAt
            ) == .reopenRequired(expiredID)
        )
    }

    @Test("Admission permanently rejects an older ID after its replacement expires or is abandoned")
    func admissionRejectsSupersededAttemptResurrection() throws {
        let owner = TransferFixtures.device()
        let origin = TransferFixtures.origin(recording: 701)
        let profile = TransferFixtures.profile()
        let first = try UploadAttempt(
            uploadID: .random(),
            ownerDeviceID: owner,
            originRecordingID: origin,
            frozenProfile: profile,
            beganAt: TransferFixtures.baseDate
        )
        let replacementBeganAt = first.generationExpiresAt.addingTimeInterval(1)
        var replacement = try UploadAttempt(
            uploadID: .random(),
            ownerDeviceID: owner,
            originRecordingID: origin,
            frozenProfile: profile,
            beganAt: replacementBeganAt
        )
        let expected = TransferValidationError.invalidUploadAttempt(
            reason: "Upload ID was permanently superseded by a newer attempt for this origin recording."
        )

        #expect(throws: expected) {
            try UploadAttemptAdmission.decide(
                proposedUploadID: first.uploadID,
                ownerDeviceID: owner,
                originRecordingID: origin,
                frozenProfile: profile,
                existingAttempts: [first, replacement],
                at: replacement.generationExpiresAt.addingTimeInterval(1)
            )
        }

        try replacement.abandon(at: replacementBeganAt.addingTimeInterval(1))
        #expect(throws: expected) {
            try UploadAttemptAdmission.decide(
                proposedUploadID: first.uploadID,
                ownerDeviceID: owner,
                originRecordingID: origin,
                frozenProfile: profile,
                existingAttempts: [first, replacement],
                at: replacementBeganAt.addingTimeInterval(2)
            )
        }
    }

    @Test("Admission requires a replacement to start strictly after an abandonment boundary")
    func admissionRejectsSameTimestampSupersessionAmbiguity() throws {
        let owner = TransferFixtures.device()
        let origin = TransferFixtures.origin(recording: 702)
        let profile = TransferFixtures.profile()
        let beganAt = TransferFixtures.baseDate
        var first = try UploadAttempt(
            uploadID: .random(),
            ownerDeviceID: owner,
            originRecordingID: origin,
            frozenProfile: profile,
            beganAt: beganAt
        )
        try first.abandon(at: beganAt)
        #expect(throws: TransferValidationError.invalidUploadAttempt(
            reason: "Replacement upload must begin strictly after the prior abandonment boundary."
        )) {
            try UploadAttemptAdmission.decide(
                proposedUploadID: .random(),
                ownerDeviceID: owner,
                originRecordingID: origin,
                frozenProfile: profile,
                existingAttempts: [first],
                at: beganAt
            )
        }

        let replacementBeganAt = beganAt.addingTimeInterval(0.001)
        let replacementID = UploadID.random()
        #expect(
            try UploadAttemptAdmission.decide(
                proposedUploadID: replacementID,
                ownerDeviceID: owner,
                originRecordingID: origin,
                frozenProfile: profile,
                existingAttempts: [first],
                at: replacementBeganAt
            ) == .create
        )
        var replacement = try UploadAttempt(
            uploadID: replacementID,
            ownerDeviceID: owner,
            originRecordingID: origin,
            frozenProfile: profile,
            beganAt: replacementBeganAt
        )
        try replacement.abandon(at: replacementBeganAt.addingTimeInterval(0.001))
        #expect(throws: TransferValidationError.invalidUploadAttempt(
            reason: "Upload ID was permanently superseded by a newer attempt for this origin recording."
        )) {
            try UploadAttemptAdmission.decide(
                proposedUploadID: first.uploadID,
                ownerDeviceID: owner,
                originRecordingID: origin,
                frozenProfile: profile,
                existingAttempts: [first, replacement],
                at: replacementBeganAt.addingTimeInterval(0.002)
            )
        }
    }

    @Test("Recording outbox supports both upload paths, explicit failures, and receipt-gated commit")
    func recordingOutbox() throws {
        var foreground = RecordingOutboxStateMachine()
        try foreground.queue()
        try foreground.beginAuthorization()
        try foreground.beginActiveUpload()
        try foreground.awaitHostCommit()
        let finalized = TransferFixtures.chunkedCapture()
        let manifest = TransferFixtures.manifestEvidence(
            uploadID: .random(),
            finalizedCapture: finalized
        )
        let evidence = TransferFixtures.receiptEvidence(manifest: manifest)
        try foreground.markCommitted(using: evidence)
        #expect(foreground.state == .committed)
        #expect(foreground.exactReceipt == evidence.exactReceiptObject)
        #expect(try JSONDecoder().decode(RecordingOutboxStateMachine.self, from: JSONEncoder().encode(foreground)) == foreground)

        var background = RecordingOutboxStateMachine()
        try background.queue()
        try background.beginAuthorization()
        try background.scheduleBackgroundUpload()
        try background.awaitHostCommit()
        #expect(background.state == .hostCommitPending)

        var failed = RecordingOutboxStateMachine()
        try failed.queue()
        try failed.failRecoverably(TransferFailure(code: "host.offline"))
        #expect(failed.state == .failedRecoverable)
        try failed.retryRecoverable()
        #expect(failed.state == .queued)
    }

    @Test("Security blocking covers authorization pin, epoch, and key-loss failures without queued retry")
    func securityBlock() throws {
        for reason in [
            TransferSecurityBlockReason.hostIdentityMismatch,
            .grantEpochChanged,
            .installationKeyLost,
        ] {
            var outbox = RecordingOutboxStateMachine()
            try outbox.queue()
            try outbox.beginAuthorization()
            try outbox.blockForSecurity(reason)
            #expect(outbox.state == .securityBlocked)
            #expect(outbox.securityBlockReason == reason)
            #expect(throws: TransferValidationError.self) { try outbox.retryRecoverable() }
            #expect(throws: TransferValidationError.self) { try outbox.beginAuthorization() }
            try outbox.resumeAfterUserSecurityAction()
            #expect(outbox.state == .queued)
        }

        var queued = RecordingOutboxStateMachine()
        try queued.queue()
        #expect(throws: TransferValidationError.invalidOutboxTransition(
            from: RecordingOutboxState.queued.rawValue,
            to: RecordingOutboxState.securityBlocked.rawValue
        )) {
            try queued.blockForSecurity(.hostIdentityMismatch)
        }
    }

    @Test("Chunk outbox distinguishes immutable ready bytes from host durability")
    func chunkOutbox() throws {
        var chunk = ChunkOutboxStateMachine()
        try chunk.beginEncoding()
        try chunk.markReady()
        try chunk.schedule()
        try chunk.markDurableAtHost()
        #expect(chunk.state == .durableAtHost)
        #expect(throws: TransferValidationError.self) {
            try chunk.failRecoverably(TransferFailure(code: "late.failure"), retryFrom: .ready)
        }

        var retry = ChunkOutboxStateMachine()
        try retry.beginEncoding()
        try retry.failRecoverably(
            TransferFailure(code: "encoder.busy"),
            retryFrom: .pending
        )
        try retry.retryRecoverable()
        #expect(retry.state == .pending)

        var exactBytesRetry = ChunkOutboxStateMachine()
        try exactBytesRetry.beginEncoding()
        try exactBytesRetry.markReady()
        try exactBytesRetry.failRecoverably(
            TransferFailure(code: "network.offline"),
            retryFrom: .ready
        )
        try exactBytesRetry.retryRecoverable()
        #expect(exactBytesRetry.state == .ready)
    }
}
