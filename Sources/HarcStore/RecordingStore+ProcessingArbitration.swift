import Foundation
import GRDB
import HarcDomain

public extension RecordingStore {
    /// Moves Host processing into the transcribing state only while no
    /// compatible edge artifact has already won the recording.
    func beginHostProcessingIfNotReady(id: Int64) async throws -> Bool {
        let descriptor = try ProcessingDescriptor(state: .transcribing)
        return try await db.write { database in
            guard let existing = try Recording.fetchOne(database, key: id) else {
                throw StoreError.notFound
            }
            guard existing.processing.state != .ready else { return false }
            guard existing.processing != descriptor else { return true }
            let now = Date()
            try database.execute(
                sql: """
                    UPDATE recordings
                    SET processing_state = ?, processing_failure_detail = ?,
                        updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    descriptor.state.rawValue,
                    encodeStoredFailure(descriptor.failure),
                    now,
                    id,
                ]
            )
            try Self.bumpRevisionAndAppendLibraryChange(
                in: database,
                recordingID: id,
                changedAt: now
            )
            return true
        }
    }

    /// Atomically installs a completed Host transcript only if an accepted
    /// edge artifact has not already made the recording ready.
    func stageHostProcessedTranscriptIfNotReady(
        recordingID: Int64,
        text: String,
        modelID: String,
        now: Date = Date()
    ) async throws -> Bool {
        let stamp = try Self.transcriptionStamp(now)
        let processing = try ProcessingDescriptor(state: .projecting)
        let projection = try ProjectionDescriptor(state: .projecting)
        return try await db.write { database in
            guard let existing = try Recording.fetchOne(
                database,
                key: recordingID
            ) else {
                throw StoreError.notFound
            }
            guard existing.processing.state != .ready else { return false }
            try database.execute(
                sql: """
                    UPDATE recordings
                    SET transcript_text = ?, stt_model_id = ?,
                        transcribed_at = ?, chunks_indexed_at = NULL,
                        processing_state = ?, processing_failure_detail = ?,
                        projection_state = ?, projection_failure_detail = ?,
                        projection_version = NULL, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    text,
                    modelID,
                    stamp,
                    processing.state.rawValue,
                    encodeStoredFailure(processing.failure),
                    projection.state.rawValue,
                    encodeStoredFailure(projection.failure),
                    now,
                    recordingID,
                ]
            )
            try database.execute(
                sql: "DELETE FROM transcript_chunks WHERE recording_id = ?",
                arguments: [recordingID]
            )
            try Self.bumpRevisionAndAppendLibraryChange(
                in: database,
                recordingID: recordingID,
                changedAt: now
            )
            return true
        }
    }

    /// Publishes the current Host-derived projection and both ready states in
    /// one writer transaction. If edge processing became ready first, this
    /// method leaves its transcript and projection untouched.
    func publishHostProcessedProjectionIfNotReady(
        recordingID: Int64,
        now: Date = Date()
    ) async throws -> Bool {
        let projection = ProjectionDescriptor.readyV1
        let processing = ProcessingDescriptor.ready
        let storedVersion = try Self.storedProjectionVersion(projection)
        return try await db.write { database in
            guard let existing = try Recording.fetchOne(
                database,
                key: recordingID
            ) else {
                throw StoreError.notFound
            }
            guard existing.processing.state != .ready else { return false }
            try database.execute(
                sql: """
                    UPDATE recordings
                    SET processing_state = ?, processing_failure_detail = ?,
                        projection_state = ?, projection_failure_detail = ?,
                        projection_version = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    processing.state.rawValue,
                    encodeStoredFailure(processing.failure),
                    projection.state.rawValue,
                    encodeStoredFailure(projection.failure),
                    storedVersion,
                    now,
                    recordingID,
                ]
            )
            try Self.bumpRevisionAndAppendLibraryChange(
                in: database,
                recordingID: recordingID,
                changedAt: now
            )
            guard let refreshed = try Recording.fetchOne(
                database,
                key: recordingID
            ), OKFProjection.write(recording: refreshed) != nil else {
                throw StoreError.writeFailed(
                    "The Host processing projection could not be published."
                )
            }
            return true
        }
    }

    /// Installs a compatible edge transcript, ready states, revision, and OKF
    /// projection as one serialized canonical-library effect.
    func applyAcceptedEdgeTranscript(
        recordingID: Int64,
        text: String,
        modelID: String,
        now: Date = Date()
    ) async throws {
        let stamp = try Self.transcriptionStamp(now)
        let projection = ProjectionDescriptor.readyV1
        let processing = ProcessingDescriptor.ready
        let storedVersion = try Self.storedProjectionVersion(projection)
        try await db.write { database in
            guard try Recording.fetchOne(database, key: recordingID) != nil else {
                throw StoreError.notFound
            }
            try database.execute(
                sql: """
                    UPDATE recordings
                    SET transcript_text = ?, stt_model_id = ?,
                        transcribed_at = ?, chunks_indexed_at = NULL,
                        processing_state = ?, processing_failure_detail = ?,
                        projection_state = ?, projection_failure_detail = ?,
                        projection_version = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    text,
                    modelID,
                    stamp,
                    processing.state.rawValue,
                    encodeStoredFailure(processing.failure),
                    projection.state.rawValue,
                    encodeStoredFailure(projection.failure),
                    storedVersion,
                    now,
                    recordingID,
                ]
            )
            try database.execute(
                sql: "DELETE FROM transcript_chunks WHERE recording_id = ?",
                arguments: [recordingID]
            )
            try Self.bumpRevisionAndAppendLibraryChange(
                in: database,
                recordingID: recordingID,
                changedAt: now
            )
            guard let refreshed = try Recording.fetchOne(
                database,
                key: recordingID
            ), OKFProjection.write(recording: refreshed) != nil else {
                throw StoreError.writeFailed(
                    "The accepted edge projection could not be published."
                )
            }
        }
    }

    /// Records a recoverable Host processing failure without regressing an
    /// edge artifact that became ready while Host work was in flight.
    func markHostProcessingFailureIfNotReady(
        recordingID: Int64,
        failure: ProcessingFailure,
        now: Date = Date()
    ) async throws -> Bool {
        let processing = try ProcessingDescriptor(
            state: .failedRecoverable,
            failure: failure
        )
        return try await db.write { database in
            guard let existing = try Recording.fetchOne(
                database,
                key: recordingID
            ) else {
                throw StoreError.notFound
            }
            guard existing.processing.state != .ready else { return false }
            let projection: ProjectionDescriptor
            if existing.projection.state == .projecting {
                projection = try ProjectionDescriptor(
                    state: .failedRecoverable,
                    failure: failure
                )
            } else {
                projection = existing.projection
            }
            let storedVersion = try Self.storedProjectionVersion(projection)
            try database.execute(
                sql: """
                    UPDATE recordings
                    SET processing_state = ?, processing_failure_detail = ?,
                        projection_state = ?, projection_failure_detail = ?,
                        projection_version = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    processing.state.rawValue,
                    encodeStoredFailure(processing.failure),
                    projection.state.rawValue,
                    encodeStoredFailure(projection.failure),
                    storedVersion,
                    now,
                    recordingID,
                ]
            )
            try Self.bumpRevisionAndAppendLibraryChange(
                in: database,
                recordingID: recordingID,
                changedAt: now
            )
            return true
        }
    }
}

private extension RecordingStore {
    static func transcriptionStamp(_ date: Date) throws -> Int64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min),
              milliseconds <= Double(Int64.max) else {
            throw StoreError.invalidData("Transcription time is out of range")
        }
        return Int64(milliseconds.rounded(.down))
    }

    static func storedProjectionVersion(
        _ descriptor: ProjectionDescriptor
    ) throws -> Int64? {
        guard let version = descriptor.version else { return nil }
        guard let value = Int64(exactly: version.rawValue) else {
            throw StoreError.invalidData(
                "Projection version exceeds SQLite range"
            )
        }
        return value
    }
}
