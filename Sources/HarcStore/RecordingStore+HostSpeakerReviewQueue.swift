import Foundation
import GRDB
import HarcDomain

/// Local work identity, independent of connection/session credentials.
public struct HostSpeakerReviewJob: Equatable, Sendable {
    public let id: UUID
    public let recordingID: Int64
    public let expectedOutcome: HostSpeakerProcessingOutcome
    public let eligibleAt: Date
    public let failureCount: Int
}

public extension RecordingStore {
    /// Exact enqueue retries retain the first job identity and its persisted backoff.
    func enqueueHostSpeakerReview(recordingID: Int64, expected: HostSpeakerProcessingOutcome,
        notBefore: Date) async throws -> HostSpeakerReviewJob? {
        guard notBefore.timeIntervalSince1970.isFinite else {
            throw StoreError.invalidData("Invalid speaker review deadline")
        }
        // Recognition cannot repair missing embeddings or disabled diarization.
        guard expected.clusters.contains(where: { $0.evidenceSHA256 != nil }) else { return nil }
        return try await db.write { database in
            guard let recording = try Recording.fetchOne(database, key: recordingID),
                  recording.deletedAt == nil, recording.processing.state == .ready,
                  recording.projection.state == .ready,
                  let bytes = try Data.fetchOne(database,
                    sql: "SELECT outcome_json FROM host_speaker_processing_outcome WHERE recording_id = ?",
                    arguments: [recordingID]),
                  try JSONDecoder().decode(HostSpeakerProcessingOutcome.self, from: bytes) == expected else { return nil }
            try Self.validateHostSpeakerOutcome(in: database, recording: recording, outcome: expected)
            if let row = try Row.fetchOne(database,
                sql: "SELECT * FROM host_speaker_review_queue WHERE recording_id = ?", arguments: [recordingID]) {
                let existing = try Self.decodeHostSpeakerReviewJob(row)
                guard existing.expectedOutcome == expected else {
                    throw StoreError.invalidData("Speaker review queue generation mismatch")
                }
                return existing
            }
            let job = HostSpeakerReviewJob(id: UUID(), recordingID: recordingID,
                expectedOutcome: expected, eligibleAt: notBefore, failureCount: 0)
            try database.execute(sql: """
                INSERT INTO host_speaker_review_queue
                (recording_id, job_uuid, expected_outcome_json, eligible_at, failure_count)
                VALUES (?, ?, ?, ?, 0)
                """, arguments: [recordingID, job.id.uuidString.lowercased(), bytes, notBefore.timeIntervalSince1970])
            return job
        }
    }

    func dueHostSpeakerReviews(at now: Date, limit: Int = 32) async throws -> [HostSpeakerReviewJob] {
        guard now.timeIntervalSince1970.isFinite, (1...128).contains(limit) else {
            throw StoreError.invalidData("Invalid speaker review inventory bounds")
        }
        return try await db.read { database in
            let rows = try Row.fetchAll(database, sql: """
                SELECT q.* FROM host_speaker_review_queue q
                JOIN recordings r ON r.id = q.recording_id
                WHERE q.eligible_at <= ? AND r.deleted_at IS NULL
                    AND r.processing_state = ? AND r.projection_state = ?
                ORDER BY q.eligible_at, q.recording_id LIMIT ?
                """, arguments: [now.timeIntervalSince1970, ProcessingDescriptor.ready.state.rawValue,
                    ProjectionDescriptor.readyV1.state.rawValue, limit])
            return try rows.map { row in
                let job = try Self.decodeHostSpeakerReviewJob(row)
                guard let recording = try Recording.fetchOne(database, key: job.recordingID),
                      let bytes = try Data.fetchOne(database,
                        sql: "SELECT outcome_json FROM host_speaker_processing_outcome WHERE recording_id = ?",
                        arguments: [job.recordingID]),
                      try JSONDecoder().decode(HostSpeakerProcessingOutcome.self, from: bytes) == job.expectedOutcome else {
                    throw StoreError.invalidData("Speaker review no longer describes the selected outcome")
                }
                try Self.validateHostSpeakerOutcome(in: database, recording: recording, outcome: job.expectedOutcome)
                return job
            }
        }
    }

    /// A stale worker cannot postpone a replacement job. Retrying enqueue cannot
    /// erase failure backoff; the same work identity survives process restart.
    func deferHostSpeakerReview(_ job: HostSpeakerReviewJob, afterFailureAt now: Date) async throws -> Bool {
        guard now.timeIntervalSince1970.isFinite else { throw StoreError.invalidData("Invalid speaker review time") }
        return try await db.write { database in
            guard let row = try Row.fetchOne(database,
                sql: "SELECT * FROM host_speaker_review_queue WHERE recording_id = ? AND job_uuid = ?",
                arguments: [job.recordingID, job.id.uuidString.lowercased()]) else { return false }
            let current = try Self.decodeHostSpeakerReviewJob(row)
            guard current == job else { return false }
            let failures = min(current.failureCount + 1, 8)
            let delays: [TimeInterval] = [5, 15, 30, 60, 300, 900, 1800, 3600]
            try database.execute(sql: """
                UPDATE host_speaker_review_queue SET failure_count = ?, eligible_at = ?
                WHERE recording_id = ? AND job_uuid = ?
                """, arguments: [failures, now.addingTimeInterval(delays[failures - 1]).timeIntervalSince1970,
                    job.recordingID, job.id.uuidString.lowercased()])
            return true
        }
    }
}

extension RecordingStore {
    static func decodeHostSpeakerReviewJob(_ row: Row) throws -> HostSpeakerReviewJob {
        let deadline: Double = row["eligible_at"]
        let failures: Int = row["failure_count"]
        guard let id = UUID(uuidString: row["job_uuid"]), deadline.isFinite, (0...8).contains(failures) else {
            throw StoreError.invalidData("Corrupt Host speaker review job")
        }
        return HostSpeakerReviewJob(id: id, recordingID: row["recording_id"],
            expectedOutcome: try JSONDecoder().decode(HostSpeakerProcessingOutcome.self, from: row["expected_outcome_json"]),
            eligibleAt: Date(timeIntervalSince1970: deadline), failureCount: failures)
    }
}
