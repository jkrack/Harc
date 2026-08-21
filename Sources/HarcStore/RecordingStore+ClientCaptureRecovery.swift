import Foundation
import GRDB
import HarcDomain

public struct ClientCaptureLibraryResult: Sendable {
    public let recording: Recording
    public let inserted: Bool

    public init(recording: Recording, inserted: Bool) {
        self.recording = recording
        self.inserted = inserted
    }
}

public extension RecordingStore {
    /// Make one verified, durable Client capture visible in this Mac's local
    /// library. Host delivery is deliberately not part of this transaction:
    /// an unavailable route must never hide or strand locally owned audio.
    func reconcileClientCapture(
        originID: OriginRecordingID,
        canonicalPCMHash: CanonicalPCMHash,
        canonicalPCMFrames: UInt64,
        masterURL: URL,
        startedAt: Date,
        endedAt: Date,
        transcriptText: String?,
        transcriptJSONURL: URL?,
        transcriptMarkdownURL: URL?,
        sttModelID: String?,
        transcribedAt: Date?
    ) async throws -> ClientCaptureLibraryResult {
        do {
            return try await db.write { database in
                let existingByOrigin = try Recording.fetchOne(
                    database,
                    sql: """
                        SELECT * FROM recordings
                        WHERE origin_device_id = ? AND origin_recording_uuid = ?
                        LIMIT 1
                        """,
                    arguments: [
                        originID.deviceID.rawBytes,
                        originID.recordingUUID.uuidString.lowercased(),
                    ]
                )
                let existingByPath = try Recording
                    .filter(Recording.Columns.wavPath == masterURL.path)
                    .fetchOne(database)

                if let existingByOrigin,
                   let existingByPath,
                   existingByOrigin.id != existingByPath.id {
                    throw StoreError.canonicalRecordingPathConflict
                }

                if var existing = existingByOrigin ?? existingByPath {
                    guard existing.originID == nil || existing.originID == originID else {
                        throw StoreError.originIdentityConflict
                    }
                    guard existing.canonicalPCMHash == nil
                            || existing.canonicalPCMHash == canonicalPCMHash,
                          existing.canonicalPCMFrames == nil
                            || existing.canonicalPCMFrames == canonicalPCMFrames else {
                        throw StoreError.canonicalPCMHashConflict
                    }
                    guard existing.wavPath == masterURL.path else {
                        throw StoreError.canonicalRecordingPathConflict
                    }

                    let shouldAdoptTranscript = transcriptText != nil && (
                        existing.transcriptText == nil
                            || (
                                existing.transcriptText == transcriptText
                                    && (existing.jsonPath == nil
                                        || existing.txtPath == nil)
                            )
                    )
                    let shouldBindIdentity = existing.originID == nil
                    if shouldBindIdentity || shouldAdoptTranscript {
                        let now = Date()
                        existing.originID = originID
                        existing.canonicalPCMHash = canonicalPCMHash
                        existing.canonicalPCMFrames = canonicalPCMFrames
                        existing.startedAt = startedAt
                        existing.endedAt = endedAt
                        if shouldAdoptTranscript {
                            existing.transcriptText = transcriptText
                            existing.jsonPath = transcriptJSONURL?.path
                            existing.txtPath = transcriptMarkdownURL?.path
                            existing.sttModelID = sttModelID
                            existing.transcribedAt = transcribedAt
                            existing.chunksIndexedAt = nil
                        }
                        existing.updatedAt = now
                        try existing.update(database)
                        guard let recordingID = existing.id else {
                            throw StoreError.invalidData(
                                "Recovered Client recording row has no identifier"
                            )
                        }
                        try Self.bumpRevisionAndAppendLibraryChange(
                            in: database,
                            recordingID: recordingID,
                            changedAt: now
                        )
                        existing = try Recording.fetchOne(
                            database,
                            key: recordingID
                        )!
                    }
                    return ClientCaptureLibraryResult(
                        recording: existing,
                        inserted: false
                    )
                }

                let now = Date()
                var inserted = Recording(
                    wavPath: masterURL.path,
                    txtPath: transcriptMarkdownURL?.path,
                    jsonPath: transcriptJSONURL?.path,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    transcriptText: transcriptText,
                    createdAt: now,
                    updatedAt: now,
                    chunksIndexedAt: nil,
                    canonicalID: .random(),
                    originID: originID,
                    canonicalPCMHash: canonicalPCMHash,
                    canonicalPCMFrames: canonicalPCMFrames,
                    revision: .initial,
                    processing: .ready,
                    projection: .readyV1
                )
                inserted.sttModelID = sttModelID
                inserted.transcribedAt = transcribedAt
                try inserted.insert(database)
                inserted.id = database.lastInsertedRowID
                guard let recordingID = inserted.id else {
                    throw StoreError.invalidData(
                        "Recovered Client recording row has no identifier"
                    )
                }
                try Self.appendLibraryChange(
                    in: database,
                    recordingID: recordingID,
                    operation: .upsert,
                    changedAt: now
                )
                return ClientCaptureLibraryResult(
                    recording: inserted,
                    inserted: true
                )
            }
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }
}
