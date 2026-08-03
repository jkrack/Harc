import CryptoKit
import Darwin
import Foundation
import GRDB
import HarcDomain
import HarcIdentity
import HarcTransfer

private let stagingBodyFragmentLimit = 1 * 1_024 * 1_024
private let stagingAuthorizationMonitorNanoseconds: UInt64 = 1_000_000_000

/// One staging loop owns each box and never starts a second `next()` until the
/// prior task group has drained. AsyncThrowingStream's iterator is not declared
/// Sendable, so the ownership invariant is expressed explicitly here.
private final class HostChunkBodyIteratorBox: @unchecked Sendable {
    private var iterator: HostChunkBody.AsyncIterator

    init(body: HostChunkBody) {
        iterator = body.makeAsyncIterator()
    }

    func next() async throws -> Data? {
        try await iterator.next()
    }
}

private actor StagingAuthorizationTimeFloor {
    private var latest: Date

    init(_ initial: Date) {
        latest = initial
    }

    func advance(to fresh: Date) throws -> Date {
        guard latest.timeIntervalSinceReferenceDate.isFinite,
              fresh.timeIntervalSinceReferenceDate.isFinite else {
            throw HarcHostError.databaseFailure("The authoritative host clock is invalid.")
        }
        if fresh > latest { latest = fresh }
        return latest
    }
}

struct HostActiveStagingWrite: Hashable, Sendable {
    let deviceID: DeviceID
    let uploadID: UploadID
    let chunkIndex: UInt32
}

private enum FinalStagingAcknowledgement {
    case acknowledged
    case rejectedByHost(HarcHostError, Date)
    case rejectedByTransfer(TransferValidationError, Date)
}

private struct StagingAuthorizationJournal: Sendable {
    let uploadID: UploadID
    let ownerDeviceID: DeviceID
    let generation: UploadGeneration
    let grantID: GrantID
    let grantEpoch: GrantEpoch
}

private struct StagingReapCandidate: Sendable {
    let uploadID: String
    let chunkIndex: Int64
    let generation: UInt64
    let relativePath: String
}

private struct StagingReapClaim: Sendable {
    let uploadID: String
    let chunkIndex: Int64
    let generation: UInt64
    let relativePath: String
    let claimID: String
    let priorStatus: String
}

private enum RestartStagingDisposition: Equatable {
    case durable
    case rejected
}

extension HarcHostStore {
    /// Loopback convenience. Transport adapters should pass `HostChunkBody`
    /// directly so network frames are consumed without whole-body buffering.
    public func stageChunk(
        context: AuthenticatedDeviceContext,
        uploadID: UploadID,
        generation: UploadGeneration,
        chunkIndex: UInt32,
        declaredEncodedLength: UInt64,
        bodyFragments: [Data]
    ) async throws -> StagedChunkDisposition {
        try await stageChunk(
            context: context,
            uploadID: uploadID,
            generation: generation,
            chunkIndex: chunkIndex,
            declaredEncodedLength: declaredEncodedLength,
            body: .fragments(bodyFragments)
        )
    }

    /// Deterministic `@testable` seam. Production staging always uses the
    /// public overload and therefore the store's injected clock.
    func stageChunk(
        context: AuthenticatedDeviceContext,
        uploadID: UploadID,
        generation: UploadGeneration,
        chunkIndex: UInt32,
        declaredEncodedLength: UInt64,
        bodyFragments: [Data],
        at date: Date
    ) async throws -> StagedChunkDisposition {
        try await stageChunk(
            context: context,
            uploadID: uploadID,
            generation: generation,
            chunkIndex: chunkIndex,
            declaredEncodedLength: declaredEncodedLength,
            body: .fragments(bodyFragments),
            at: date
        )
    }

    /// Stages one previously declared encoded chunk. Transport adapters must
    /// feed bounded fragments; HarcHost never allocates the declared body as a
    /// single buffer. The durable disposition is returned only after file
    /// synchronization and the HostDB acknowledgement transaction.
    public func stageChunk(
        context: AuthenticatedDeviceContext,
        uploadID: UploadID,
        generation: UploadGeneration,
        chunkIndex: UInt32,
        declaredEncodedLength: UInt64,
        body: HostChunkBody
    ) async throws -> StagedChunkDisposition {
        try await stageChunk(
            context: context,
            uploadID: uploadID,
            generation: generation,
            chunkIndex: chunkIndex,
            declaredEncodedLength: declaredEncodedLength,
            body: body,
            at: now()
        )
    }

    /// Deterministic `@testable` seam. The supplied value is inaccessible to
    /// production clients and is still clamped against the injected clock.
    func stageChunk(
        context: AuthenticatedDeviceContext,
        uploadID: UploadID,
        generation: UploadGeneration,
        chunkIndex: UInt32,
        declaredEncodedLength: UInt64,
        body: HostChunkBody,
        at date: Date
    ) async throws -> StagedChunkDisposition {
        try await repairSecurityRegistryOnReopen()
        let activeWrite = HostActiveStagingWrite(
            deviceID: context.authenticatedDeviceID,
            uploadID: uploadID,
            chunkIndex: chunkIndex
        )
        guard !activeStagingWrites.contains(where: {
            $0.uploadID == uploadID && $0.chunkIndex == chunkIndex
        }) else {
            throw HarcHostError.uploadConflict("This chunk already has an active staging writer.")
        }
        guard activeStagingWrites.lazy.filter({
            $0.deviceID == context.authenticatedDeviceID
        }).count < TransferLimits.activeStagingStreamsPerDevice else {
            throw HarcHostError.activeStagingStreamLimitExceeded(
                limit: TransferLimits.activeStagingStreamsPerDevice
            )
        }
        activeStagingWrites.insert(activeWrite)
        defer { activeStagingWrites.remove(activeWrite) }
        let stagedAt = try freshStagingAuthorizationTime(notBefore: date)
        try await reconcileStagedChunkBeforeWrite(uploadID: uploadID, chunkIndex: chunkIndex)
        _ = try await reapEligibleStaging(at: stagedAt)

        struct Reservation {
            let descriptor: LogicalChunkDescriptor
            let relativePath: String
            let oldRelativePath: String?
            let replay: DurableChunkStatus?
            let grantExpiresAt: Date?
            let generationExpiresAt: Date
        }

        let reservation: Reservation = try await dbQueue.write { db in
            guard let attempt = try self.fetchUploadAttempt(in: db, uploadID: uploadID) else {
                throw HarcHostError.uploadNotFound
            }
            _ = try self.authorizeInDatabase(
                db,
                context: context,
                requiredScope: .recordingUploadOwn,
                objectOwner: attempt.ownerDeviceID,
                at: stagedAt
            )
            let grantExpiresAt = try self.currentGrantExpiry(
                in: db,
                deviceID: context.authenticatedDeviceID
            )
            do {
                try attempt.requireActive(generation: generation, at: stagedAt)
            } catch TransferValidationError.staleUploadGeneration(let expected, let actual) {
                throw HarcHostError.staleUploadGeneration(expected: expected, actual: actual)
            }
            guard let descriptor = attempt.declarations.descriptors.first(where: { $0.chunkIndex == chunkIndex }) else {
                throw HarcHostError.uploadConflict("Chunk bytes arrived before an immutable declaration.")
            }
            guard descriptor.encodedByteLength == declaredEncodedLength else {
                throw HarcHostError.encodedLengthMismatch(
                    expected: descriptor.encodedByteLength,
                    actual: declaredEncodedLength
                )
            }
            guard declaredEncodedLength <= TransferLimits.encodedChunkBytes else {
                throw HarcHostError.encodedLengthMismatch(
                    expected: TransferLimits.encodedChunkBytes,
                    actual: declaredEncodedLength
                )
            }

            var oldRelativePath: String?
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM staged_chunks WHERE upload_id = ? AND chunk_index = ?",
                arguments: [uploadID.description, Int64(chunkIndex)]
            ) {
                guard existing["chunk_id"] as String == descriptor.chunkID.description,
                      existing["expected_encoded_length"] as Int64 == (try Self.sqliteInteger(descriptor.encodedByteLength, field: "encodedByteLength")),
                      existing["expected_encoded_sha256"] as Data == descriptor.encodedSHA256.rawBytes else {
                    throw HarcHostError.uploadConflict("The staging journal does not match the immutable descriptor.")
                }
                let existingStatus = existing["status"] as String
                let restoredDurableReap = try self.restoreDurableStagingReapForActiveRetryIfPresent(
                    existing,
                    descriptor: descriptor,
                    activeGeneration: generation,
                    in: db,
                    at: stagedAt
                )
                if existingStatus == "durable" || restoredDurableReap {
                    return Reservation(
                        descriptor: descriptor,
                        relativePath: existing["generated_relative_path"],
                        oldRelativePath: nil,
                        replay: DurableChunkStatus(
                            chunkIndex: descriptor.chunkIndex,
                            chunkID: descriptor.chunkID,
                            encodedSHA256: descriptor.encodedSHA256
                        ),
                        grantExpiresAt: grantExpiresAt,
                        generationExpiresAt: attempt.generationExpiresAt
                    )
                }
                oldRelativePath = existing["generated_relative_path"]
            }

            let excludedLength = try Int64.fetchOne(
                db,
                sql: """
                    SELECT expected_encoded_length FROM staged_chunks
                    WHERE upload_id = ? AND chunk_index = ?
                      AND (
                          status IN ('writing', 'durable')
                          OR (status IN ('rejected', 'reaping') AND object_deleted_at IS NULL)
                      )
                    """,
                arguments: [uploadID.description, Int64(chunkIndex)]
            ) ?? 0
            let deviceUsed = (try Int64.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(SUM(expected_encoded_length), 0)
                    FROM staged_chunks
                    WHERE owner_device_id = ?
                      AND (
                          status IN ('writing', 'durable')
                          OR (status IN ('rejected', 'reaping') AND object_deleted_at IS NULL)
                      )
                    """,
                arguments: [attempt.ownerDeviceID.rawBytes]
            ) ?? 0) - excludedLength
            let globalUsed = (try Int64.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(SUM(expected_encoded_length), 0)
                    FROM staged_chunks
                    WHERE status IN ('writing', 'durable')
                       OR (status IN ('rejected', 'reaping') AND object_deleted_at IS NULL)
                    """
            ) ?? 0) - excludedLength
            let declaredValue = try Self.sqliteInteger(declaredEncodedLength, field: "encodedByteLength")
            let projectedDevice = try Self.unsigned(deviceUsed + declaredValue, field: "deviceStagingBytes")
            let projectedGlobal = try Self.unsigned(globalUsed + declaredValue, field: "globalStagingBytes")
            guard projectedDevice <= self.quotaPolicy.perDeviceBytes else {
                throw HarcHostError.quotaExceeded(
                    scope: "per-device",
                    limit: self.quotaPolicy.perDeviceBytes,
                    requestedTotal: projectedDevice
                )
            }
            guard projectedGlobal <= self.quotaPolicy.globalBytes else {
                throw HarcHostError.quotaExceeded(
                    scope: "global",
                    limit: self.quotaPolicy.globalBytes,
                    requestedTotal: projectedGlobal
                )
            }
            let capacity = try self.capacityProvider.capacity(for: self.stagingRoot)
            let percentageFloor = capacity.totalBytes
                .multipliedReportingOverflow(by: UInt64(self.quotaPolicy.minimumFreePermille))
            guard !percentageFloor.overflow else {
                throw HarcHostError.volumeCapacityUnavailable
            }
            let requiredRemaining = max(
                self.quotaPolicy.minimumFreeBytes,
                percentageFloor.partialValue / 1_000
            )
            let projectedRemaining = capacity.availableBytes >= declaredEncodedLength
                ? capacity.availableBytes - declaredEncodedLength
                : 0
            guard projectedRemaining >= requiredRemaining else {
                throw HarcHostError.insufficientFreeSpace(
                    requiredRemaining: requiredRemaining,
                    projectedRemaining: projectedRemaining
                )
            }

            let generatedPath = "objects/\(UUID().uuidString.lowercased()).chunk"
            try db.execute(
                sql: """
                    INSERT INTO staged_chunks (
                        upload_id, chunk_index, chunk_id, owner_device_id,
                        generation, authenticated_grant_id,
                        authenticated_grant_epoch, generated_relative_path,
                        expected_encoded_length, expected_encoded_sha256,
                        persisted_encoded_length, persisted_encoded_sha256,
                        status, rejected_reason, file_synchronized_at,
                        durable_acknowledged_at, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, 'writing', NULL, NULL, NULL, ?, ?)
                    ON CONFLICT(upload_id, chunk_index) DO UPDATE SET
                        generation = excluded.generation,
                        authenticated_grant_id = excluded.authenticated_grant_id,
                        authenticated_grant_epoch = excluded.authenticated_grant_epoch,
                        generated_relative_path = excluded.generated_relative_path,
                        persisted_encoded_length = NULL,
                        persisted_encoded_sha256 = NULL,
                        status = 'writing',
                        rejected_reason = NULL,
                        file_synchronized_at = NULL,
                        durable_acknowledged_at = NULL,
                        object_deleted_at = NULL,
                        reap_claim_id = NULL,
                        reap_prior_status = NULL,
                        reap_claimed_at = NULL,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    uploadID.description,
                    Int64(chunkIndex),
                    descriptor.chunkID.description,
                    attempt.ownerDeviceID.rawBytes,
                    try Self.sqliteInteger(generation.rawValue, field: "uploadGeneration"),
                    context.grantID.description,
                    try Self.sqliteInteger(context.grantEpoch.rawValue, field: "grantEpoch"),
                    generatedPath,
                    declaredValue,
                    descriptor.encodedSHA256.rawBytes,
                    Self.unixTime(stagedAt),
                    Self.unixTime(stagedAt),
                ]
            )
            return Reservation(
                descriptor: descriptor,
                relativePath: generatedPath,
                oldRelativePath: oldRelativePath,
                replay: nil,
                grantExpiresAt: grantExpiresAt,
                generationExpiresAt: attempt.generationExpiresAt
            )
        }

        if let replay = reservation.replay { return .exactReplay(replay) }
        // The reservation is durable before any obsolete object is unlinked.
        // A real process death here can therefore leave an unreferenced object;
        // reopen reconciliation enumerates the complete generated namespace and
        // removes it before the host admits another upload.
        try await stagingFailureInjector.hit(.afterJournalReservation)
        if let oldRelativePath = reservation.oldRelativePath {
            try removeGeneratedStagingObjectIfSafe(relativePath: oldRelativePath)
        }

        let descriptor = reservation.descriptor
        let objectName = try HostStagingDirectory.objectName(
            forGeneratedRelativePath: reservation.relativePath
        )
        let fileDescriptor: Int32
        do {
            fileDescriptor = try stagingDirectory.createExclusiveObject(named: objectName)
        } catch {
            try await rejectStagingReservation(
                uploadID: uploadID,
                chunkIndex: chunkIndex,
                relativePath: reservation.relativePath,
                reason: .missingBytes,
                at: stagedAt
            )
            throw error
        }
        defer { close(fileDescriptor) }
        try await stagingFailureInjector.hit(.afterFileCreation)

        var hasher = SHA256()
        var written: UInt64 = 0
        var lastAuthorizationCheckAt = stagedAt
        let authorizationTimeFloor = StagingAuthorizationTimeFloor(stagedAt)
        let bodyIterator = HostChunkBodyIteratorBox(body: body)
        while true {
            let nextFragment: Data?
            do {
                nextFragment = try await nextAuthorizedStagingFragment(
                    iterator: bodyIterator,
                    context: context,
                    uploadID: uploadID,
                    generation: generation,
                    chunkIndex: chunkIndex,
                    relativePath: reservation.relativePath,
                    timeFloor: authorizationTimeFloor
                )
                if nextFragment != nil {
                    // The monitor may have lost the race to a newly available
                    // fragment. Reauthorize again before accepting its bytes.
                    lastAuthorizationCheckAt = try await reauthorizeActiveStagingWrite(
                        context: context,
                        uploadID: uploadID,
                        generation: generation,
                        chunkIndex: chunkIndex,
                        relativePath: reservation.relativePath,
                        timeFloor: authorizationTimeFloor
                    )
                }
            } catch {
                let rejectedAt = (try? await authorizationTimeFloor.advance(to: now()))
                    ?? lastAuthorizationCheckAt
                try await rejectStagingReservation(
                    uploadID: uploadID,
                    chunkIndex: chunkIndex,
                    relativePath: reservation.relativePath,
                    reason: .missingBytes,
                    at: rejectedAt
                )
                throw error
            }
            guard let fragment = nextFragment else { break }
            guard fragment.count <= stagingBodyFragmentLimit else {
                try await rejectStagingReservation(
                    uploadID: uploadID,
                    chunkIndex: chunkIndex,
                    relativePath: reservation.relativePath,
                    reason: .lengthMismatch,
                    at: stagedAt
                )
                throw HarcHostError.bodyFragmentTooLarge(
                    limit: stagingBodyFragmentLimit,
                    actual: fragment.count
                )
            }
            let newLength = written.addingReportingOverflow(UInt64(fragment.count))
            guard !newLength.overflow, newLength.partialValue <= descriptor.encodedByteLength else {
                try await rejectStagingReservation(
                    uploadID: uploadID,
                    chunkIndex: chunkIndex,
                    relativePath: reservation.relativePath,
                    reason: .lengthMismatch,
                    at: stagedAt
                )
                throw HarcHostError.encodedLengthMismatch(
                    expected: descriptor.encodedByteLength,
                    actual: newLength.partialValue
                )
            }
            try writeAll(fragment, to: fileDescriptor)
            hasher.update(data: fragment)
            written = newLength.partialValue
        }

        try await stagingFailureInjector.hit(.afterBodyWrite)
        guard written == descriptor.encodedByteLength else {
            try await rejectStagingReservation(
                uploadID: uploadID,
                chunkIndex: chunkIndex,
                relativePath: reservation.relativePath,
                reason: .lengthMismatch,
                at: stagedAt
            )
            throw HarcHostError.incompleteBody
        }
        let digest = Data(hasher.finalize())
        guard digest == descriptor.encodedSHA256.rawBytes else {
            try await rejectStagingReservation(
                uploadID: uploadID,
                chunkIndex: chunkIndex,
                relativePath: reservation.relativePath,
                reason: .encodedHashMismatch,
                at: stagedAt
            )
            throw HarcHostError.encodedHashMismatch
        }
        try stagingDirectory.validateOpenObject(fileDescriptor, named: objectName)
        guard fsync(fileDescriptor) == 0 else {
            throw HarcHostError.stagingIO(String(cString: strerror(errno)))
        }
        try await stagingFailureInjector.hit(.afterFileSynchronization)
        try synchronizeStagingObjectsDirectory()
        try stagingDirectory.validateOpenObject(fileDescriptor, named: objectName)
        try await stagingFailureInjector.hit(.afterDirectorySynchronization)

        let postSynchronizationCheckAt = try await authorizationTimeFloor.advance(to: now())
        do {
            try validateStagingLease(
                grantExpiresAt: reservation.grantExpiresAt,
                generationExpiresAt: reservation.generationExpiresAt,
                at: postSynchronizationCheckAt
            )
        } catch {
            try await rejectStagingReservation(
                uploadID: uploadID,
                chunkIndex: chunkIndex,
                relativePath: reservation.relativePath,
                reason: .missingBytes,
                at: postSynchronizationCheckAt
            )
            throw error
        }
        let persistedLength = written
        try await repairSecurityRegistryOnReopen()
        let acknowledgement: FinalStagingAcknowledgement = try await dbQueue.write { db in
            let acknowledgedAt = try self.freshStagingAuthorizationTime(
                notBefore: postSynchronizationCheckAt
            )
            guard let attempt = try self.fetchUploadAttempt(in: db, uploadID: uploadID) else {
                throw HarcHostError.uploadNotFound
            }
            do {
                _ = try self.authorizeInDatabase(
                    db,
                    context: context,
                    requiredScope: .recordingUploadOwn,
                    objectOwner: attempt.ownerDeviceID,
                    at: acknowledgedAt
                )
            } catch let error as HarcHostError {
                return .rejectedByHost(error, acknowledgedAt)
            }
            do {
                try attempt.requireActive(generation: generation, at: acknowledgedAt)
            } catch let error as TransferValidationError {
                return .rejectedByTransfer(error, acknowledgedAt)
            }
            try db.execute(
                sql: """
                    UPDATE staged_chunks SET
                        persisted_encoded_length = ?, persisted_encoded_sha256 = ?,
                        status = 'durable', rejected_reason = NULL,
                        file_synchronized_at = ?, durable_acknowledged_at = ?,
                        object_deleted_at = NULL,
                        reap_claim_id = NULL, reap_prior_status = NULL,
                        reap_claimed_at = NULL,
                        updated_at = ?
                    WHERE upload_id = ? AND chunk_index = ?
                      AND generated_relative_path = ? AND status = 'writing'
                    """,
                arguments: [
                    try Self.sqliteInteger(persistedLength, field: "persistedEncodedLength"),
                    digest,
                    Self.unixTime(acknowledgedAt),
                    Self.unixTime(acknowledgedAt),
                    Self.unixTime(acknowledgedAt),
                    uploadID.description,
                    Int64(chunkIndex),
                    reservation.relativePath,
                ]
            )
            guard db.changesCount == 1 else {
                throw HarcHostError.stagingIO("The durable staging acknowledgement lost its journal reservation.")
            }
            return .acknowledged
        }
        switch acknowledgement {
        case .acknowledged:
            break
        case .rejectedByHost(let error, let rejectedAt):
            try await rejectStagingReservation(
                uploadID: uploadID,
                chunkIndex: chunkIndex,
                relativePath: reservation.relativePath,
                reason: .missingBytes,
                at: rejectedAt
            )
            throw error
        case .rejectedByTransfer(let error, let rejectedAt):
            try await rejectStagingReservation(
                uploadID: uploadID,
                chunkIndex: chunkIndex,
                relativePath: reservation.relativePath,
                reason: .missingBytes,
                at: rejectedAt
            )
            if case .staleUploadGeneration(let expected, let actual) = error {
                throw HarcHostError.staleUploadGeneration(expected: expected, actual: actual)
            }
            throw error
        }
        try await stagingFailureInjector.hit(.afterDatabaseAcknowledgement)
        return .durablyAccepted(
            DurableChunkStatus(
                chunkIndex: descriptor.chunkIndex,
                chunkID: descriptor.chunkID,
                encodedSHA256: descriptor.encodedSHA256
            )
        )
    }
}

// MARK: - Restart reconciliation and safe filesystem access

extension HarcHostStore {
    func reconcileStagingJournalOnReopen() async throws {
        try stagingDirectory.validate()
        try stagingDirectory.synchronizeRoot()
        try stagingDirectory.synchronizeObjects()
        // Capture the namespace before awaiting the database snapshot. A new
        // writer that reserves and creates a path while the read is suspended
        // is not in this enumeration and cannot be mistaken for an orphan.
        let generatedPathsOnDisk = try generatedStagingRelativePathsOnDisk()
        let rows = try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT upload_id, chunk_index, generated_relative_path,
                           expected_encoded_length, expected_encoded_sha256,
                           generation, status, object_deleted_at,
                           reap_claim_id, reap_prior_status, reap_claimed_at
                    FROM staged_chunks
                    ORDER BY upload_id, chunk_index
                    """
            )
        }
        let referencedPaths = Set(rows.map { $0["generated_relative_path"] as String })
        // A database transaction can replace a journal path before the old
        // file is unlinked. If the process dies in that window, only a complete
        // namespace comparison can find the old bytes; status-based quota SQL
        // cannot. Bootstrap does not complete until every such object is gone.
        for relativePath in generatedPathsOnDisk.subtracting(referencedPaths).sorted() {
            try removeGeneratedStagingObject(relativePath: relativePath)
        }

        let activeWrites = activeStagingWrites
        for row in rows {
            let relativePath = row["generated_relative_path"] as String
            var status = row["status"] as String
            if status == "reaping" {
                guard let restoredStatus = try await resolveInterruptedStagingReapOnReopen(
                    row,
                    objectWasPresent: generatedPathsOnDisk.contains(relativePath)
                ) else {
                    continue
                }
                status = restoredStatus
            }
            if status == "rejected" {
                // Rejection is committed before unlink. A crash in between
                // leaves a referenced object that is intentionally excluded
                // from ordinary durable rows, so reopen must remove it before
                // recording the deletion that releases its quota reservation.
                if generatedPathsOnDisk.contains(relativePath)
                    || (row["object_deleted_at"] as Double?) == nil
                {
                    try removeGeneratedStagingObjectIfSafe(relativePath: relativePath)
                    guard let rawUploadID = UUID(uuidString: row["upload_id"] as String),
                          let index = UInt32(exactly: row["chunk_index"] as Int64) else {
                        throw HarcHostError.databaseFailure(
                            "Malformed rejected staging journal identity."
                        )
                    }
                    try await markStagedChunkObjectDeleted(
                        uploadID: UploadID(rawUploadID),
                        chunkIndex: index,
                        relativePath: relativePath,
                        at: now()
                    )
                }
                continue
            }
            if let rawUploadID = UUID(uuidString: row["upload_id"] as String),
               let index = UInt32(exactly: row["chunk_index"] as Int64),
               activeWrites.contains(where: {
                   $0.uploadID == UploadID(rawUploadID) && $0.chunkIndex == index
               }) {
                continue
            }
            let uploadID = row["upload_id"] as String
            let chunkIndex = row["chunk_index"] as Int64
            let expectedLength = try Self.unsigned(
                row["expected_encoded_length"] as Int64,
                field: "expectedEncodedLength"
            )
            let expectedDigest = row["expected_encoded_sha256"] as Data
            let result = try inspectGeneratedStagingObject(
                relativePath: relativePath,
                expectedLength: expectedLength,
                expectedDigest: expectedDigest
            )
            let reconciledAt = now()
            switch result {
            case .durable(let length, let digest):
                let disposition = try await persistRestartStagingInspection(
                    uploadID: uploadID,
                    chunkIndex: chunkIndex,
                    relativePath: relativePath,
                    persistedLength: length,
                    persistedDigest: digest,
                    checkedAtFloor: reconciledAt
                )
                if disposition == .rejected {
                    try removeGeneratedStagingObjectIfSafe(relativePath: relativePath)
                    guard let rawUploadID = UUID(uuidString: uploadID),
                          let index = UInt32(exactly: chunkIndex) else {
                        throw HarcHostError.databaseFailure(
                            "Malformed rejected staging journal identity."
                        )
                    }
                    try await markStagedChunkObjectDeleted(
                        uploadID: UploadID(rawUploadID),
                        chunkIndex: index,
                        relativePath: relativePath,
                        at: reconciledAt
                    )
                }
            case .rejected(let reason):
                try removeGeneratedStagingObjectIfSafe(relativePath: relativePath)
                try await dbQueue.write { db in
                    try db.execute(
                        sql: """
                            UPDATE staged_chunks SET
                                persisted_encoded_length = NULL,
                                persisted_encoded_sha256 = NULL,
                                status = 'rejected', rejected_reason = ?,
                                file_synchronized_at = NULL,
                                durable_acknowledged_at = NULL,
                                object_deleted_at = ?,
                                reap_claim_id = NULL,
                                reap_prior_status = NULL,
                                reap_claimed_at = NULL,
                                updated_at = ?
                            WHERE upload_id = ? AND chunk_index = ?
                            """,
                        arguments: [
                            reason.rawValue,
                            Self.unixTime(reconciledAt),
                            Self.unixTime(reconciledAt),
                            uploadID,
                            chunkIndex,
                        ]
                    )
                }
            }
        }
    }

    /// A crash can leave either a claimed-but-present object or a durably
    /// unlinked object awaiting exact journal finalization. Reopen completes an
    /// eligible claim, restores a claim invalidated by a later upload reopen,
    /// and never exposes a missing object as durable while doing so.
    private func resolveInterruptedStagingReapOnReopen(
        _ snapshot: Row,
        objectWasPresent: Bool
    ) async throws -> String? {
        guard let claimID = snapshot["reap_claim_id"] as String?,
              let priorStatus = snapshot["reap_prior_status"] as String?,
              let rawClaimedAt = snapshot["reap_claimed_at"] as Double? else {
            throw HarcHostError.databaseFailure("Malformed staging reap claim.")
        }
        let claim = StagingReapClaim(
            uploadID: snapshot["upload_id"] as String,
            chunkIndex: snapshot["chunk_index"] as Int64,
            generation: try Self.unsigned(
                snapshot["generation"] as Int64,
                field: "stagedChunkGeneration"
            ),
            relativePath: snapshot["generated_relative_path"] as String,
            claimID: claimID,
            priorStatus: priorStatus
        )
        let checkedAt = try freshStagingAuthorizationTime(
            notBefore: Self.date(rawClaimedAt)
        )
        return try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT s.generation, s.generated_relative_path, s.status,
                           s.object_deleted_at, s.reap_claim_id,
                           s.reap_prior_status, u.attempt_json
                    FROM staged_chunks s
                    JOIN uploads u ON u.upload_id = s.upload_id
                    WHERE s.upload_id = ? AND s.chunk_index = ?
                    """,
                arguments: [claim.uploadID, claim.chunkIndex]
            ), row["status"] as String == "reaping",
               row["reap_claim_id"] as String? == claim.claimID,
               row["reap_prior_status"] as String? == claim.priorStatus,
               row["generated_relative_path"] as String == claim.relativePath,
               try Self.unsigned(
                   row["generation"] as Int64,
                   field: "stagedChunkGeneration"
               ) == claim.generation else {
                throw HarcHostError.databaseFailure(
                    "The interrupted staging reap claim changed during reopen."
                )
            }

            let attempt = try Self.decode(
                UploadAttempt.self,
                from: row["attempt_json"] as Data
            )
            if objectWasPresent,
               (row["object_deleted_at"] as Double?) == nil,
               !Self.stagingRetentionIsEligible(
                   attempt,
                   at: checkedAt,
                   retention: TransferLimits.abandonedStagingRetention
               ) {
                try self.restoreStagingReapClaim(claim, in: db, at: checkedAt)
                return claim.priorStatus
            }

            if objectWasPresent {
                try self.removeGeneratedStagingObject(relativePath: claim.relativePath)
            }
            try db.execute(
                sql: """
                    DELETE FROM staged_chunks
                    WHERE upload_id = ? AND chunk_index = ?
                      AND generation = ? AND generated_relative_path = ?
                      AND status = 'reaping' AND reap_claim_id = ?
                      AND reap_prior_status = ?
                    """,
                arguments: [
                    claim.uploadID,
                    claim.chunkIndex,
                    try Self.sqliteInteger(claim.generation, field: "stagedChunkGeneration"),
                    claim.relativePath,
                    claim.claimID,
                    claim.priorStatus,
                ]
            )
            guard db.changesCount == 1 else {
                throw HarcHostError.databaseFailure(
                    "The interrupted staging reap claim lost exact finalization."
                )
            }
            return nil
        }
    }

    /// Enumerates only names Harc itself can generate. Unexpected local files
    /// are outside the protocol-owned object namespace; valid UUID chunk names
    /// (including symlinks or non-regular entries) are always reconciled.
    private func generatedStagingRelativePathsOnDisk() throws -> Set<String> {
        var paths: Set<String> = []
        for name in try stagingDirectory.generatedObjectNames() {
            let relativePath = "objects/\(name)"
            guard (try? HostStagingDirectory.objectName(
                forGeneratedRelativePath: relativePath
            )) != nil else {
                continue
            }
            paths.insert(relativePath)
        }
        return paths
    }

    /// A retry reconciles only its own prior journal row. Reconciling every
    /// `writing` row here would race another permitted upload stream while its
    /// body is intentionally partial.
    private func reconcileStagedChunkBeforeWrite(
        uploadID: UploadID,
        chunkIndex: UInt32
    ) async throws {
        try stagingDirectory.validate()
        try stagingDirectory.synchronizeRoot()
        try stagingDirectory.synchronizeObjects()
        guard let row = try await dbQueue.read({ db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT upload_id, chunk_index, generated_relative_path,
                           expected_encoded_length, expected_encoded_sha256, status
                    FROM staged_chunks
                    WHERE upload_id = ? AND chunk_index = ?
                      AND status IN ('writing', 'durable')
                    """,
                arguments: [uploadID.description, Int64(chunkIndex)]
            )
        }) else { return }

        let relativePath = row["generated_relative_path"] as String
        let expectedLength = try Self.unsigned(
            row["expected_encoded_length"] as Int64,
            field: "expectedEncodedLength"
        )
        let result = try inspectGeneratedStagingObject(
            relativePath: relativePath,
            expectedLength: expectedLength,
            expectedDigest: row["expected_encoded_sha256"] as Data
        )
        let reconciledAt = now()
        switch result {
        case .durable(let length, let digest):
            let disposition = try await persistRestartStagingInspection(
                uploadID: uploadID.description,
                chunkIndex: Int64(chunkIndex),
                relativePath: relativePath,
                persistedLength: length,
                persistedDigest: digest,
                checkedAtFloor: reconciledAt
            )
            if disposition == .rejected {
                try removeGeneratedStagingObjectIfSafe(relativePath: relativePath)
                try await markStagedChunkObjectDeleted(
                    uploadID: uploadID,
                    chunkIndex: chunkIndex,
                    relativePath: relativePath,
                    at: reconciledAt
                )
            }
        case .rejected(let reason):
            try removeGeneratedStagingObjectIfSafe(relativePath: relativePath)
            try await markStagedChunkRejected(
                uploadID: uploadID,
                chunkIndex: chunkIndex,
                reason: reason,
                at: reconciledAt
            )
            try await markStagedChunkObjectDeleted(
                uploadID: uploadID,
                chunkIndex: chunkIndex,
                relativePath: relativePath,
                at: reconciledAt
            )
        }
    }

    private enum StagingInspection {
        case durable(length: UInt64, digest: Data)
        case rejected(RejectedChunkReason)
    }

    nonisolated private func inspectGeneratedStagingObject(
        relativePath: String,
        expectedLength: UInt64,
        expectedDigest: Data
    ) throws -> StagingInspection {
        guard let objectName = try? HostStagingDirectory.objectName(
            forGeneratedRelativePath: relativePath
        ) else {
            return .rejected(.missingBytes)
        }
        // Reopen recovery must be able to make a pre-ACK file durable before
        // changing its journal row to durable. O_RDWR is intentional: fsync on
        // a read-only descriptor is not a portable durability contract.
        guard let descriptor = try? stagingDirectory.openExistingObject(
            named: objectName,
            writable: true
        ) else { return .rejected(.missingBytes) }
        defer { close(descriptor) }

        var hasher = SHA256()
        var length: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: stagingBodyFragmentLimit)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 { return .rejected(.missingBytes) }
            if count == 0 { break }
            let next = length.addingReportingOverflow(UInt64(count))
            guard !next.overflow, next.partialValue <= expectedLength else {
                return .rejected(.lengthMismatch)
            }
            hasher.update(data: Data(buffer[0 ..< count]))
            length = next.partialValue
        }
        guard length == expectedLength else { return .rejected(.lengthMismatch) }
        let digest = Data(hasher.finalize())
        guard digest == expectedDigest else { return .rejected(.encodedHashMismatch) }
        guard fsync(descriptor) == 0 else {
            throw HarcHostError.stagingIO(String(cString: strerror(errno)))
        }
        try stagingDirectory.validateOpenObject(descriptor, named: objectName)
        try synchronizeStagingObjectsDirectory()
        return .durable(length: length, digest: digest)
    }

    /// A reap claim is only provisional until the object unlink is recorded.
    /// An active retry means a later upload generation has invalidated that
    /// claim. Preserve an intact, previously durable object as an exact replay
    /// instead of replacing it before the retry body has itself become durable.
    nonisolated private func restoreDurableStagingReapForActiveRetryIfPresent(
        _ row: Row,
        descriptor: LogicalChunkDescriptor,
        activeGeneration: UploadGeneration,
        in db: Database,
        at restoredAt: Date
    ) throws -> Bool {
        guard row["status"] as String == "reaping",
              (row["object_deleted_at"] as Double?) == nil,
              row["reap_prior_status"] as String? == "durable",
              let claimID = row["reap_claim_id"] as String? else {
            return false
        }
        let relativePath = row["generated_relative_path"] as String
        let claimedGeneration = try Self.unsigned(
            row["generation"] as Int64,
            field: "stagedChunkGeneration"
        )
        guard claimedGeneration < activeGeneration.rawValue else {
            return false
        }
        guard case .durable = try inspectGeneratedStagingObject(
            relativePath: relativePath,
            expectedLength: descriptor.encodedByteLength,
            expectedDigest: descriptor.encodedSHA256.rawBytes
        ) else {
            return false
        }
        let claim = StagingReapClaim(
            uploadID: row["upload_id"] as String,
            chunkIndex: row["chunk_index"] as Int64,
            generation: claimedGeneration,
            relativePath: relativePath,
            claimID: claimID,
            priorStatus: "durable"
        )
        try restoreStagingReapClaim(claim, in: db, at: restoredAt)
        guard db.changesCount == 1 else {
            throw HarcHostError.databaseFailure(
                "The active staging retry lost its durable reap restoration."
            )
        }
        return true
    }

    nonisolated private func synchronizeStagingObjectsDirectory() throws {
        try stagingDirectory.synchronizeObjects()
    }

    /// Races the next transport fragment against a bounded authorization
    /// monitor. AsyncThrowingStream's iterator responds to task cancellation,
    /// so an invalid grant/upload lease terminates an otherwise idle body.
    private func nextAuthorizedStagingFragment(
        iterator: HostChunkBodyIteratorBox,
        context: AuthenticatedDeviceContext,
        uploadID: UploadID,
        generation: UploadGeneration,
        chunkIndex: UInt32,
        relativePath: String,
        timeFloor: StagingAuthorizationTimeFloor
    ) async throws -> Data? {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                try await iterator.next()
            }
            group.addTask { [self] in
                do {
                    while true {
                        try Task.checkCancellation()
                        try await Task.sleep(
                            nanoseconds: stagingAuthorizationMonitorNanoseconds
                        )
                        _ = try await reauthorizeActiveStagingWrite(
                            context: context,
                            uploadID: uploadID,
                            generation: generation,
                            chunkIndex: chunkIndex,
                            relativePath: relativePath,
                            timeFloor: timeFloor
                        )
                    }
                } catch is CancellationError {
                    return nil
                }
            }
            do {
                guard let result = try await group.next() else {
                    throw HarcHostError.incompleteBody
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    /// Revalidates the session against the current registry row and the upload
    /// attempt against its current generation/status. Cached expiry timestamps
    /// are deliberately insufficient: revocation, scope changes, replacement
    /// grants, and abandonment must stop an active writer.
    private func reauthorizeActiveStagingWrite(
        context: AuthenticatedDeviceContext,
        uploadID: UploadID,
        generation: UploadGeneration,
        chunkIndex: UInt32,
        relativePath: String,
        timeFloor: StagingAuthorizationTimeFloor
    ) async throws -> Date {
        let checkedAt = try await timeFloor.advance(to: now())
        try await repairSecurityRegistryOnReopen()
        return try await dbQueue.read { db in
            guard let attempt = try self.fetchUploadAttempt(in: db, uploadID: uploadID) else {
                throw HarcHostError.uploadNotFound
            }
            _ = try self.authorizeInDatabase(
                db,
                context: context,
                requiredScope: .recordingUploadOwn,
                objectOwner: attempt.ownerDeviceID,
                at: checkedAt
            )
            do {
                try attempt.requireActive(generation: generation, at: checkedAt)
            } catch TransferValidationError.staleUploadGeneration(let expected, let actual) {
                throw HarcHostError.staleUploadGeneration(expected: expected, actual: actual)
            }
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT owner_device_id, generation, authenticated_grant_id,
                           authenticated_grant_epoch, generated_relative_path,
                           status
                    FROM staged_chunks
                    WHERE upload_id = ? AND chunk_index = ?
                    """,
                arguments: [uploadID.description, Int64(chunkIndex)]
            ), row["owner_device_id"] as Data == attempt.ownerDeviceID.rawBytes,
               row["generation"] as Int64 == (try Self.sqliteInteger(
                   generation.rawValue,
                   field: "uploadGeneration"
               )),
               row["authenticated_grant_id"] as String == context.grantID.description,
               row["authenticated_grant_epoch"] as Int64 == (try Self.sqliteInteger(
                   context.grantEpoch.rawValue,
                   field: "grantEpoch"
               )),
               row["generated_relative_path"] as String == relativePath,
               row["status"] as String == "writing" else {
                throw HarcHostError.stagingIO(
                    "The active staging authorization journal changed during streaming."
                )
            }
            return checkedAt
        }
    }

    /// Reads the injected host clock on every call and prevents a backwards
    /// wall-clock adjustment from extending an already-observed lease.
    nonisolated private func freshStagingAuthorizationTime(
        notBefore prior: Date
    ) throws -> Date {
        let fresh = now()
        guard prior.timeIntervalSinceReferenceDate.isFinite,
              fresh.timeIntervalSinceReferenceDate.isFinite else {
            throw HarcHostError.databaseFailure("The authoritative host clock is invalid.")
        }
        return fresh > prior ? fresh : prior
    }

    nonisolated private func validateStagingLease(
        grantExpiresAt: Date?,
        generationExpiresAt: Date,
        at checkedAt: Date
    ) throws {
        if let grantExpiresAt, checkedAt >= grantExpiresAt {
            throw HarcHostError.grantExpired
        }
        if checkedAt >= generationExpiresAt {
            throw TransferValidationError.uploadExpired
        }
    }

    /// A complete pre-ACK file is only promotable when the exact journaled
    /// session grant is still current and the same upload generation is live
    /// at a fresh authoritative host time. Already-durable rows are historical
    /// acceptance evidence and are not invalidated by later revocation.
    private func persistRestartStagingInspection(
        uploadID: String,
        chunkIndex: Int64,
        relativePath: String,
        persistedLength: UInt64,
        persistedDigest: Data,
        checkedAtFloor: Date
    ) async throws -> RestartStagingDisposition {
        try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT upload_id, chunk_index, owner_device_id, generation,
                           authenticated_grant_id, authenticated_grant_epoch,
                           generated_relative_path, status, updated_at
                    FROM staged_chunks
                    WHERE upload_id = ? AND chunk_index = ?
                    """,
                arguments: [uploadID, chunkIndex]
            ), row["generated_relative_path"] as String == relativePath else {
                throw HarcHostError.databaseFailure(
                    "The staging authorization journal changed during reconciliation."
                )
            }
            let currentStatus = row["status"] as String
            if currentStatus == "rejected" { return .rejected }

            let priorUpdate = Self.date(row["updated_at"] as Double)
            let checkedAt = try self.freshStagingAuthorizationTime(
                notBefore: max(checkedAtFloor, priorUpdate)
            )
            if currentStatus == "writing" {
                let journal = try self.stagingAuthorizationJournal(from: row)
                let authorized = try self.restartStagingAuthorizationIsValid(
                    journal,
                    in: db,
                    at: checkedAt
                )
                if !authorized {
                    try db.execute(
                        sql: """
                            UPDATE staged_chunks SET
                                persisted_encoded_length = NULL,
                                persisted_encoded_sha256 = NULL,
                                status = 'rejected', rejected_reason = ?,
                                file_synchronized_at = NULL,
                                durable_acknowledged_at = NULL,
                                object_deleted_at = NULL,
                                reap_claim_id = NULL,
                                reap_prior_status = NULL,
                                reap_claimed_at = NULL,
                                updated_at = ?
                            WHERE upload_id = ? AND chunk_index = ?
                              AND generated_relative_path = ? AND status = 'writing'
                            """,
                        arguments: [
                            RejectedChunkReason.missingBytes.rawValue,
                            Self.unixTime(checkedAt),
                            uploadID,
                            chunkIndex,
                            relativePath,
                        ]
                    )
                    guard db.changesCount == 1 else {
                        throw HarcHostError.databaseFailure(
                            "The rejected staging recovery transition was lost."
                        )
                    }
                    return .rejected
                }
            } else if currentStatus != "durable" {
                throw HarcHostError.databaseFailure("Unknown staged chunk status.")
            }

            try db.execute(
                sql: """
                    UPDATE staged_chunks SET
                        persisted_encoded_length = ?, persisted_encoded_sha256 = ?,
                        status = 'durable', rejected_reason = NULL,
                        file_synchronized_at = COALESCE(file_synchronized_at, ?),
                        durable_acknowledged_at = COALESCE(durable_acknowledged_at, ?),
                        object_deleted_at = NULL,
                        reap_claim_id = NULL, reap_prior_status = NULL,
                        reap_claimed_at = NULL,
                        updated_at = ?
                    WHERE upload_id = ? AND chunk_index = ?
                      AND generated_relative_path = ?
                      AND status IN ('writing', 'durable')
                    """,
                arguments: [
                    try Self.sqliteInteger(persistedLength, field: "persistedEncodedLength"),
                    persistedDigest,
                    Self.unixTime(checkedAt),
                    Self.unixTime(checkedAt),
                    Self.unixTime(checkedAt),
                    uploadID,
                    chunkIndex,
                    relativePath,
                ]
            )
            guard db.changesCount == 1 else {
                throw HarcHostError.databaseFailure(
                    "The durable staging recovery transition was lost."
                )
            }
            return .durable
        }
    }

    nonisolated private func stagingAuthorizationJournal(
        from row: Row
    ) throws -> StagingAuthorizationJournal {
        guard let uploadUUID = UUID(uuidString: row["upload_id"] as String),
              let grantUUID = UUID(uuidString: row["authenticated_grant_id"] as String) else {
            throw HarcHostError.databaseFailure("Malformed staging authorization identity.")
        }
        return StagingAuthorizationJournal(
            uploadID: UploadID(uploadUUID),
            ownerDeviceID: try DeviceID(row["owner_device_id"] as Data),
            generation: try UploadGeneration(
                Self.unsigned(row["generation"] as Int64, field: "uploadGeneration")
            ),
            grantID: GrantID(grantUUID),
            grantEpoch: try GrantEpoch(
                Self.unsigned(row["authenticated_grant_epoch"] as Int64, field: "grantEpoch")
            )
        )
    }

    nonisolated private func restartStagingAuthorizationIsValid(
        _ journal: StagingAuthorizationJournal,
        in db: Database,
        at checkedAt: Date
    ) throws -> Bool {
        guard let attempt = try fetchUploadAttempt(in: db, uploadID: journal.uploadID) else {
            throw HarcHostError.uploadNotFound
        }
        guard attempt.ownerDeviceID == journal.ownerDeviceID else {
            throw HarcHostError.databaseFailure(
                "The staging authorization owner conflicts with its upload."
            )
        }
        let context = AuthenticatedDeviceContext(
            libraryID: expectedMetadata.libraryID,
            hostAuthorityID: expectedMetadata.hostAuthorityID,
            authenticatedDeviceID: journal.ownerDeviceID,
            grantID: journal.grantID,
            grantEpoch: journal.grantEpoch
        )
        do {
            _ = try authorizeInDatabase(
                db,
                context: context,
                requiredScope: .recordingUploadOwn,
                objectOwner: journal.ownerDeviceID,
                at: checkedAt
            )
            try attempt.requireActive(generation: journal.generation, at: checkedAt)
            return true
        } catch let error as HarcHostError {
            switch error {
            case .unknownDevice, .deviceRevoked, .grantExpired, .grantMismatch,
                 .missingScope, .objectOwnershipMismatch:
                return false
            default:
                throw error
            }
        } catch is TransferValidationError {
            return false
        }
    }

    /// Persist rejection before unlinking so a process death cannot turn
    /// rejected bytes into a restart-time durable acknowledgement. The same
    /// post-database failure point used for a positive acknowledgement also
    /// models a process death after this durable negative acknowledgement.
    private func rejectStagingReservation(
        uploadID: UploadID,
        chunkIndex: UInt32,
        relativePath: String,
        reason: RejectedChunkReason,
        at rejectedAt: Date
    ) async throws {
        try await markStagedChunkRejected(
            uploadID: uploadID,
            chunkIndex: chunkIndex,
            reason: reason,
            at: rejectedAt
        )
        try await stagingFailureInjector.hit(.afterDatabaseAcknowledgement)
        try removeGeneratedStagingObject(relativePath: relativePath)
        let deletedAt = try freshStagingAuthorizationTime(notBefore: rejectedAt)
        try await markStagedChunkObjectDeleted(
            uploadID: uploadID,
            chunkIndex: chunkIndex,
            relativePath: relativePath,
            at: deletedAt
        )
    }

    /// Deletes staging bytes only after a durable receipt, or after an
    /// abandoned/expired attempt's retention window has elapsed. Upload
    /// identity, declarations, generation history, and bound object identity
    /// remain in HostDB for deterministic replay decisions.
    @discardableResult
    public func reapEligibleStaging() async throws -> Int {
        try await reapEligibleStaging(at: now())
    }

    /// Deterministic `@testable` seam. Production retention decisions use the
    /// public overload backed by the store's injected clock.
    @discardableResult
    func reapEligibleStaging(at date: Date) async throws -> Int {
        let reapedAt = date
        let retention = TransferLimits.abandonedStagingRetention
        try await stagingFailureInjector.hit(.beforeReapCandidateRead)
        let candidates: [StagingReapCandidate] = try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.upload_id, s.chunk_index, s.generation,
                           s.generated_relative_path, s.status, u.attempt_json
                    FROM staged_chunks s
                    JOIN uploads u ON u.upload_id = s.upload_id
                    ORDER BY s.upload_id, s.chunk_index
                    """
            )
            return try rows.compactMap { row in
                let attempt = try Self.decode(UploadAttempt.self, from: row["attempt_json"] as Data)
                guard try Self.publicationAllowsStagingReap(
                    attempt,
                    uploadID: row["upload_id"] as String,
                    in: db
                ) else {
                    return nil
                }
                // An interrupted claim must remain discoverable even if its
                // upload was reopened after the claim transaction committed.
                // The exact-claim transaction below either restores or finishes it.
                guard row["status"] as String == "reaping"
                        || Self.stagingRetentionIsEligible(
                            attempt,
                            at: reapedAt,
                            retention: retention
                        ) else {
                    return nil
                }
                return StagingReapCandidate(
                    uploadID: row["upload_id"] as String,
                    chunkIndex: row["chunk_index"] as Int64,
                    generation: try Self.unsigned(
                        row["generation"] as Int64,
                        field: "stagedChunkGeneration"
                    ),
                    relativePath: row["generated_relative_path"] as String
                )
            }
        }
        try await stagingFailureInjector.hit(.afterReapCandidateSnapshot)

        var deletedCount = 0
        for candidate in candidates {
            guard let rawUploadID = UUID(uuidString: candidate.uploadID) else {
                throw HarcHostError.databaseFailure("Malformed staged upload identity.")
            }
            let uploadID = UploadID(rawUploadID)
            let chunkIndex = try Self.stagingChunkIndex(candidate.chunkIndex)
            guard !activeStagingWrites.contains(where: {
                $0.uploadID == uploadID && $0.chunkIndex == chunkIndex
            }) else { continue }

            guard let claim = try await claimEligibleStagingCandidate(
                candidate,
                at: reapedAt,
                retention: retention
            ) else { continue }
            try await stagingFailureInjector.hit(.afterReapCandidateClaim)

            // A writer can be admitted while the claim transaction is awaited.
            // Restore only this token; a writer that already replaced the row
            // wins and its new path is never touched by this reaper.
            if activeStagingWrites.contains(where: {
                $0.uploadID == uploadID && $0.chunkIndex == chunkIndex
            }) {
                try await releaseStagingReapClaim(claim, at: reapedAt)
                continue
            }

            // Eligibility, the exact claim, and unlink are checked in one HostDB
            // write transaction. A concurrent reopen therefore orders either
            // before this transaction (and restores the claim) or after the
            // object is already represented as non-durable `reaping` state.
            let objectWasUnlinked: Bool
            do {
                objectWasUnlinked = try await unlinkClaimedStagingObjectIfStillEligible(
                    claim,
                    at: reapedAt,
                    retention: retention
                )
            } catch {
                // Transaction 1 already committed `reaping`, so a failure after
                // unlink can never roll back to a publicly durable row. Repair
                // the exact claim immediately when possible; if repair itself
                // fails, the committed non-durable claim remains fail-closed for
                // the next reap or bootstrap reconciliation.
                try await repairFailedStagingReapTransaction(
                    claim,
                    at: reapedAt,
                    retention: retention
                )
                throw error
            }
            guard objectWasUnlinked else { continue }
            try await stagingFailureInjector.hit(.afterReapObjectDeletion)

            deletedCount += try await finalizeStagingReapClaim(claim)
        }
        return deletedCount
    }

    nonisolated private static func stagingRetentionIsEligible(
        _ attempt: UploadAttempt,
        at reapedAt: Date,
        retention: TimeInterval
    ) -> Bool {
        let eligibilityDate: Date?
        switch attempt.status {
        case .abandoned:
            eligibilityDate = attempt.terminalAt
        case .active:
            eligibilityDate = attempt.generationExpiresAt
        case .committed:
            // UploadAttempt can enter this state only after exact validated
            // receipt evidence is durably stored. Canonical publication no
            // longer depends on the encoded staging objects at that point.
            return true
        case .conflictBlocked:
            eligibilityDate = nil
        }
        guard let eligibilityDate else { return false }
        return reapedAt >= eligibilityDate.addingTimeInterval(retention)
    }

    private func claimEligibleStagingCandidate(
        _ candidate: StagingReapCandidate,
        at reapedAt: Date,
        retention: TimeInterval
    ) async throws -> StagingReapClaim? {
        try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT s.generated_relative_path, s.generation, s.status,
                           s.object_deleted_at, s.reap_claim_id,
                           s.reap_prior_status, u.attempt_json
                    FROM staged_chunks s
                    JOIN uploads u ON u.upload_id = s.upload_id
                    WHERE s.upload_id = ? AND s.chunk_index = ?
                    """,
                arguments: [candidate.uploadID, candidate.chunkIndex]
            ), row["generated_relative_path"] as String == candidate.relativePath,
               try Self.unsigned(
                   row["generation"] as Int64,
                   field: "stagedChunkGeneration"
               ) == candidate.generation else {
                return nil
            }
            let attempt = try Self.decode(
                UploadAttempt.self,
                from: row["attempt_json"] as Data
            )
            guard try Self.publicationAllowsStagingReap(
                attempt,
                uploadID: candidate.uploadID,
                in: db
            ) else {
                if row["status"] as String == "reaping",
                   let claimID = row["reap_claim_id"] as String?,
                   let priorStatus = row["reap_prior_status"] as String? {
                    try self.restoreStagingReapClaim(
                        StagingReapClaim(
                            uploadID: candidate.uploadID,
                            chunkIndex: candidate.chunkIndex,
                            generation: candidate.generation,
                            relativePath: candidate.relativePath,
                            claimID: claimID,
                            priorStatus: priorStatus
                        ),
                        in: db,
                        at: reapedAt
                    )
                }
                return nil
            }
            guard candidate.generation <= attempt.generation.rawValue else {
                throw HarcHostError.databaseFailure(
                    "A staged chunk belongs to a future upload generation."
                )
            }

            let status = row["status"] as String
            if status == "reaping" {
                guard let claimID = row["reap_claim_id"] as String?,
                      let priorStatus = row["reap_prior_status"] as String? else {
                    throw HarcHostError.databaseFailure("Malformed staging reap claim.")
                }
                let claim = StagingReapClaim(
                    uploadID: candidate.uploadID,
                    chunkIndex: candidate.chunkIndex,
                    generation: candidate.generation,
                    relativePath: candidate.relativePath,
                    claimID: claimID,
                    priorStatus: priorStatus
                )
                // Once transaction 2 has durably recorded the unlink, a later
                // reopen cannot resurrect the prior status. Any nested reaper
                // must finish this exact tombstoned claim instead.
                if (row["object_deleted_at"] as Double?) != nil {
                    return claim
                }
                guard Self.stagingRetentionIsEligible(
                    attempt,
                    at: reapedAt,
                    retention: retention
                ) else {
                    try self.restoreStagingReapClaim(claim, in: db, at: reapedAt)
                    return nil
                }
                return claim
            }

            guard ["writing", "durable", "rejected"].contains(status),
                  Self.stagingRetentionIsEligible(
                      attempt,
                      at: reapedAt,
                      retention: retention
                  ) else {
                return nil
            }
            let claimID = UUID().uuidString.lowercased()
            try db.execute(
                sql: """
                    UPDATE staged_chunks SET
                        status = 'reaping', reap_claim_id = ?,
                        reap_prior_status = ?, reap_claimed_at = ?, updated_at = ?
                    WHERE upload_id = ? AND chunk_index = ?
                      AND generation = ? AND generated_relative_path = ?
                      AND status = ? AND reap_claim_id IS NULL
                    """,
                arguments: [
                    claimID,
                    status,
                    Self.unixTime(reapedAt),
                    Self.unixTime(reapedAt),
                    candidate.uploadID,
                    candidate.chunkIndex,
                    try Self.sqliteInteger(candidate.generation, field: "stagedChunkGeneration"),
                    candidate.relativePath,
                    status,
                ]
            )
            guard db.changesCount == 1 else { return nil }
            return StagingReapClaim(
                uploadID: candidate.uploadID,
                chunkIndex: candidate.chunkIndex,
                generation: candidate.generation,
                relativePath: candidate.relativePath,
                claimID: claimID,
                priorStatus: status
            )
        }
    }

    private func releaseStagingReapClaim(
        _ claim: StagingReapClaim,
        at releasedAt: Date
    ) async throws {
        try await dbQueue.write { db in
            try self.restoreStagingReapClaim(claim, in: db, at: releasedAt)
        }
    }

    nonisolated private func restoreStagingReapClaim(
        _ claim: StagingReapClaim,
        in db: Database,
        at restoredAt: Date
    ) throws {
        try db.execute(
            sql: """
                UPDATE staged_chunks SET
                    status = ?, reap_claim_id = NULL,
                    reap_prior_status = NULL, reap_claimed_at = NULL,
                    updated_at = ?
                WHERE upload_id = ? AND chunk_index = ?
                  AND generation = ? AND generated_relative_path = ?
                  AND status = 'reaping' AND reap_claim_id = ?
                  AND reap_prior_status = ? AND object_deleted_at IS NULL
                """,
            arguments: [
                claim.priorStatus,
                Self.unixTime(restoredAt),
                claim.uploadID,
                claim.chunkIndex,
                try Self.sqliteInteger(claim.generation, field: "stagedChunkGeneration"),
                claim.relativePath,
                claim.claimID,
                claim.priorStatus,
            ]
        )
    }

    private func unlinkClaimedStagingObjectIfStillEligible(
        _ claim: StagingReapClaim,
        at reapedAt: Date,
        retention: TimeInterval
    ) async throws -> Bool {
        try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT s.generation, s.generated_relative_path, s.status,
                           s.object_deleted_at, s.reap_claim_id,
                           s.reap_prior_status, u.attempt_json
                    FROM staged_chunks s
                    JOIN uploads u ON u.upload_id = s.upload_id
                    WHERE s.upload_id = ? AND s.chunk_index = ?
                    """,
                arguments: [claim.uploadID, claim.chunkIndex]
            ), row["status"] as String == "reaping",
               row["reap_claim_id"] as String? == claim.claimID,
               row["reap_prior_status"] as String? == claim.priorStatus,
               row["generated_relative_path"] as String == claim.relativePath,
               try Self.unsigned(
                   row["generation"] as Int64,
                   field: "stagedChunkGeneration"
               ) == claim.generation else {
                return false
            }
            let attempt = try Self.decode(
                UploadAttempt.self,
                from: row["attempt_json"] as Data
            )
            if (row["object_deleted_at"] as Double?) != nil {
                return true
            }
            guard try Self.publicationAllowsStagingReap(
                attempt,
                uploadID: claim.uploadID,
                in: db
            ), Self.stagingRetentionIsEligible(
                attempt,
                at: reapedAt,
                retention: retention
            ) else {
                try self.restoreStagingReapClaim(claim, in: db, at: reapedAt)
                return false
            }
            do {
                try self.removeGeneratedStagingObject(relativePath: claim.relativePath)
            } catch HarcHostError.unsafeStagingPath {
                try self.restoreStagingReapClaim(claim, in: db, at: reapedAt)
                return false
            }
            try db.execute(
                sql: """
                    UPDATE staged_chunks SET object_deleted_at = ?, updated_at = ?
                    WHERE upload_id = ? AND chunk_index = ?
                      AND generation = ? AND generated_relative_path = ?
                      AND status = 'reaping' AND reap_claim_id = ?
                      AND reap_prior_status = ?
                    """,
                arguments: [
                    Self.unixTime(reapedAt),
                    Self.unixTime(reapedAt),
                    claim.uploadID,
                    claim.chunkIndex,
                    try Self.sqliteInteger(claim.generation, field: "stagedChunkGeneration"),
                    claim.relativePath,
                    claim.claimID,
                    claim.priorStatus,
                ]
            )
            guard db.changesCount == 1 else {
                throw HarcHostError.databaseFailure(
                    "The staging reap deletion marker lost its exact claim."
                )
            }
            return true
        }
    }

    private func repairFailedStagingReapTransaction(
        _ claim: StagingReapClaim,
        at checkedAt: Date,
        retention: TimeInterval
    ) async throws {
        let objectStillExists: Bool
        do {
            let objectName = try HostStagingDirectory.objectName(
                forGeneratedRelativePath: claim.relativePath
            )
            objectStillExists = try stagingDirectory.objectEntryIsPresent(
                named: objectName
            )
        } catch HarcHostError.unsafeStagingPath {
            // A corrupted path is never dereferenced. Keep the claim fail-closed
            // and let bootstrap's exact repair discard its journal row.
            return
        }

        try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT s.generation, s.generated_relative_path, s.status,
                           s.reap_claim_id, s.reap_prior_status, u.attempt_json
                    FROM staged_chunks s
                    JOIN uploads u ON u.upload_id = s.upload_id
                    WHERE s.upload_id = ? AND s.chunk_index = ?
                    """,
                arguments: [claim.uploadID, claim.chunkIndex]
            ), row["status"] as String == "reaping",
               row["reap_claim_id"] as String? == claim.claimID,
               row["reap_prior_status"] as String? == claim.priorStatus,
               row["generated_relative_path"] as String == claim.relativePath,
               try Self.unsigned(
                   row["generation"] as Int64,
                   field: "stagedChunkGeneration"
               ) == claim.generation else {
                return
            }
            if !objectStillExists {
                try db.execute(
                    sql: """
                        DELETE FROM staged_chunks
                        WHERE upload_id = ? AND chunk_index = ?
                          AND generation = ? AND generated_relative_path = ?
                          AND status = 'reaping' AND reap_claim_id = ?
                          AND reap_prior_status = ?
                        """,
                    arguments: [
                        claim.uploadID,
                        claim.chunkIndex,
                        try Self.sqliteInteger(claim.generation, field: "stagedChunkGeneration"),
                        claim.relativePath,
                        claim.claimID,
                        claim.priorStatus,
                    ]
                )
                return
            }

            let attempt = try Self.decode(
                UploadAttempt.self,
                from: row["attempt_json"] as Data
            )
            if try !Self.publicationAllowsStagingReap(
                attempt,
                uploadID: claim.uploadID,
                in: db
            ) || !Self.stagingRetentionIsEligible(
                attempt,
                at: checkedAt,
                retention: retention
            ) {
                try self.restoreStagingReapClaim(claim, in: db, at: checkedAt)
            }
        }
    }

    private func finalizeStagingReapClaim(_ claim: StagingReapClaim) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    DELETE FROM staged_chunks
                    WHERE upload_id = ? AND chunk_index = ?
                      AND generation = ? AND generated_relative_path = ?
                      AND status = 'reaping' AND reap_claim_id = ?
                      AND reap_prior_status = ? AND object_deleted_at IS NOT NULL
                    """,
                arguments: [
                    claim.uploadID,
                    claim.chunkIndex,
                    try Self.sqliteInteger(claim.generation, field: "stagedChunkGeneration"),
                    claim.relativePath,
                    claim.claimID,
                    claim.priorStatus,
                ]
            )
            return db.changesCount
        }
    }

    /// An accepted publication plan owns its staged inputs until its exact
    /// receipt becomes durable. This closes the race where an old upload lease
    /// expires while crash recovery is still between canonical checkpoints.
    nonisolated private static func publicationAllowsStagingReap(
        _ attempt: UploadAttempt,
        uploadID: String,
        in db: Database
    ) throws -> Bool {
        if attempt.status == .committed { return true }
        return try Int.fetchOne(
            db,
            sql: "SELECT 1 FROM publication_journal WHERE upload_id = ? LIMIT 1",
            arguments: [uploadID]
        ) == nil
    }

    nonisolated private func removeGeneratedStagingObject(relativePath: String) throws {
        let objectName = try HostStagingDirectory.objectName(
            forGeneratedRelativePath: relativePath
        )
        try stagingDirectory.removeGeneratedEntryIfPresent(named: objectName)
    }

    /// A corrupted journal path must never become an arbitrary unlink. Valid
    /// generated paths still propagate unlink/fsync failures so the database
    /// cannot forget bytes whose directory removal is not durable.
    private func removeGeneratedStagingObjectIfSafe(relativePath: String) throws {
        guard let objectName = try? HostStagingDirectory.objectName(
            forGeneratedRelativePath: relativePath
        ) else { return }
        try stagingDirectory.removeGeneratedEntryIfPresent(named: objectName)
    }

    nonisolated private static func stagingChunkIndex(_ value: Int64) throws -> UInt32 {
        guard let index = UInt32(exactly: value) else {
            throw HarcHostError.databaseFailure("Staged chunk index is outside UInt32 range.")
        }
        return index
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw HarcHostError.stagingIO(String(cString: strerror(errno)))
                }
                guard count > 0 else { throw HarcHostError.stagingIO("write returned zero") }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
    }

    private func markStagedChunkRejected(
        uploadID: UploadID,
        chunkIndex: UInt32,
        reason: RejectedChunkReason,
        at date: Date
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE staged_chunks SET
                        persisted_encoded_length = NULL,
                        persisted_encoded_sha256 = NULL,
                        status = 'rejected', rejected_reason = ?,
                        file_synchronized_at = NULL,
                        durable_acknowledged_at = NULL,
                        object_deleted_at = NULL,
                        reap_claim_id = NULL,
                        reap_prior_status = NULL,
                        reap_claimed_at = NULL,
                        updated_at = ?
                    WHERE upload_id = ? AND chunk_index = ?
                    """,
                arguments: [
                    reason.rawValue,
                    Self.unixTime(date),
                    uploadID.description,
                    Int64(chunkIndex),
                ]
            )
        }
    }

    private func markStagedChunkObjectDeleted(
        uploadID: UploadID,
        chunkIndex: UInt32,
        relativePath: String,
        at date: Date
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE staged_chunks SET object_deleted_at = ?, updated_at = ?
                    WHERE upload_id = ? AND chunk_index = ?
                      AND generated_relative_path = ? AND status = 'rejected'
                    """,
                arguments: [
                    Self.unixTime(date),
                    Self.unixTime(date),
                    uploadID.description,
                    Int64(chunkIndex),
                    relativePath,
                ]
            )
            guard db.changesCount == 1 else {
                throw HarcHostError.databaseFailure(
                    "The rejected staging object deletion marker lost its journal reservation."
                )
            }
        }
    }

    // Internal hooks for focused path-corruption/reopen tests. They never form
    // part of a production request surface.
    func stagingRelativePathForTesting(uploadID: UploadID, chunkIndex: UInt32) async throws -> String? {
        try await dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT generated_relative_path FROM staged_chunks WHERE upload_id = ? AND chunk_index = ?",
                arguments: [uploadID.description, Int64(chunkIndex)]
            )
        }
    }

    func replaceStagingRelativePathForTesting(
        uploadID: UploadID,
        chunkIndex: UInt32,
        relativePath: String
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE staged_chunks SET generated_relative_path = ?, status = 'writing', object_deleted_at = NULL, reap_claim_id = NULL, reap_prior_status = NULL, reap_claimed_at = NULL WHERE upload_id = ? AND chunk_index = ?",
                arguments: [relativePath, uploadID.description, Int64(chunkIndex)]
            )
        }
    }
}
