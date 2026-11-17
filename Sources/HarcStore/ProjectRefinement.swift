import Foundation
import CryptoKit
import GRDB
import HarcDomain

/// Local-only derived knowledge. These types are not Host RPC authority or DTOs.
public struct KnowledgeProject: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let version: UUID
}

public enum ProjectReviewDecision: String, Codable, Sendable {
    case pending, accepted, rejected, unsure
}

/// Evidence is a verbatim excerpt, not an assertion that the inferred link is true.
/// No seek timestamp is supplied until the caller has qualified timing provenance.
public struct ProjectMatchReview: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let recordingID: Int64
    public let canonicalID: CanonicalRecordingID
    public let project: KnowledgeProject
    public let recordingRevision: EntityRevision
    public let transcriptSHA256: String
    public let quote: String
    public let generatorID: String
    public var decision: ProjectReviewDecision
    public var version: UUID
}

/// A human assignment survives retranscription, but its original supporting
/// evidence must be visibly marked stale rather than presented as current proof.
public struct ConfirmedProjectMatch: Sendable, Equatable {
    public let review: ProjectMatchReview
    public let evidenceIsCurrent: Bool
}

public struct ProjectReviewReceipt: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let reviewID: UUID
    public let decision: ProjectReviewDecision
    /// Actual newly linked distinct recordings in this transaction (0 or 1).
    /// This is not a model-quality, precision or predicted-reach measurement.
    public let newlyLinkedRecordings: Int
}

public enum ProjectRefinementError: Error, Equatable {
    case missing, invalidEvidence, staleEvidence, conflict, operationMismatch
}

private struct ProjectReviewEvent: Codable {
    let before: ProjectMatchReview
    let after: ProjectMatchReview
    let receipt: ProjectReviewReceipt
}

private func transcriptDigest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

extension DatabaseMigrator {
    static func registerProjectRefinementMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v34_project_refinement") { db in
            try db.execute(sql: """
                CREATE TABLE knowledge_projects (
                    id TEXT PRIMARY KEY NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE TABLE project_match_reviews (
                    id TEXT PRIMARY KEY NOT NULL,
                    recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
                    project_id TEXT NOT NULL REFERENCES knowledge_projects(id) ON DELETE CASCADE,
                    payload BLOB NOT NULL,
                    UNIQUE(recording_id, project_id)
                );
                CREATE TABLE project_review_events (
                    operation_id TEXT PRIMARY KEY NOT NULL,
                    review_id TEXT NOT NULL REFERENCES project_match_reviews(id) ON DELETE CASCADE,
                    payload BLOB NOT NULL,
                    undone INTEGER NOT NULL DEFAULT 0 CHECK(undone IN (0, 1))
                );
                """)
        }
    }
}

private func loadReview(_ db: Database, id: UUID) throws -> ProjectMatchReview {
    guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM project_match_reviews WHERE id = ?", arguments: [id.uuidString]) else {
        throw ProjectRefinementError.missing
    }
    return try JSONDecoder().decode(ProjectMatchReview.self, from: data)
}

private func saveReview(_ db: Database, review: ProjectMatchReview) throws {
    try db.execute(sql: "UPDATE project_match_reviews SET payload = ? WHERE id = ?",
                   arguments: [try JSONEncoder().encode(review), review.id.uuidString])
}

private func validateEvidence(_ db: Database, review: ProjectMatchReview) throws {
    guard let recording = try Recording.fetchOne(db, key: review.recordingID),
          recording.deletedAt == nil,
          let projectData = try Data.fetchOne(db, sql: "SELECT payload FROM knowledge_projects WHERE id = ?", arguments: [review.project.id.uuidString]) else {
        throw ProjectRefinementError.missing
    }
    let project = try JSONDecoder().decode(KnowledgeProject.self, from: projectData)
    guard recording.canonicalID == review.canonicalID,
          project.id == review.project.id, project.version == review.project.version,
          let text = recording.transcriptText,
          transcriptDigest(text) == review.transcriptSHA256,
          !review.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          text.contains(review.quote) else { throw ProjectRefinementError.staleEvidence }
}

public extension RecordingStore {
    func createKnowledgeProject(name: String, id: UUID = UUID()) async throws -> KnowledgeProject {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectRefinementError.invalidEvidence }
        let project = KnowledgeProject(id: id, name: name, version: UUID())
        return try await db.write { database in
            try database.execute(sql: "INSERT INTO knowledge_projects(id, payload) VALUES (?, ?)",
                                 arguments: [id.uuidString, try JSONEncoder().encode(project)])
            return project
        }
    }

    /// Regeneration never overwrites human decisions, including unsure. A stale
    /// pending suggestion must be refreshed explicitly, not silently rebound.
    func proposeProjectMatch(recordingID: Int64, projectID: UUID, quote: String, generatorID: String) async throws -> ProjectMatchReview {
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !generatorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectRefinementError.invalidEvidence
        }
        return try await db.write { database in
            guard let activeRecording = try Recording.fetchOne(database, key: recordingID),
                  activeRecording.deletedAt == nil else { throw ProjectRefinementError.missing }
            if let data = try Data.fetchOne(database, sql: "SELECT payload FROM project_match_reviews WHERE recording_id = ? AND project_id = ?", arguments: [recordingID, projectID.uuidString]) {
                return try JSONDecoder().decode(ProjectMatchReview.self, from: data)
            }
            guard let recording = try Recording.fetchOne(database, key: recordingID),
                  let data = try Data.fetchOne(database, sql: "SELECT payload FROM knowledge_projects WHERE id = ?", arguments: [projectID.uuidString]) else { throw ProjectRefinementError.missing }
            guard let transcript = recording.transcriptText, transcript.contains(quote) else { throw ProjectRefinementError.invalidEvidence }
            let project = try JSONDecoder().decode(KnowledgeProject.self, from: data)
            let review = ProjectMatchReview(id: UUID(), recordingID: recordingID, canonicalID: recording.canonicalID,
                project: project, recordingRevision: recording.revision, transcriptSHA256: transcriptDigest(transcript),
                quote: quote, generatorID: generatorID, decision: .pending, version: UUID())
            try database.execute(sql: "INSERT INTO project_match_reviews(id, recording_id, project_id, payload) VALUES (?, ?, ?, ?)",
                arguments: [review.id.uuidString, recordingID, projectID.uuidString, try JSONEncoder().encode(review)])
            return review
        }
    }

    /// Historical decisions remain inspectable after evidence becomes stale.
    func projectMatchReview(id: UUID) async throws -> ProjectMatchReview {
        try await db.read { database in
            let review = try loadReview(database, id: id)
            guard let recording = try Recording.fetchOne(database, key: review.recordingID),
                  recording.deletedAt == nil else { throw ProjectRefinementError.missing }
            return review
        }
    }

    /// Human assignments remain intact across transcript updates. The caller
    /// must distinguish a retained assignment from current supporting evidence.
    /// Trashed recordings are never projected.
    func confirmedProjectMatches(recordingID: Int64) async throws -> [ConfirmedProjectMatch] {
        try await db.read { database in
            guard let recording = try Recording.fetchOne(database, key: recordingID),
                  recording.deletedAt == nil else { return [] }
            let data = try Data.fetchAll(database, sql: "SELECT payload FROM project_match_reviews WHERE recording_id = ? ORDER BY id", arguments: [recordingID])
            return try data.compactMap { data in
                let review = try JSONDecoder().decode(ProjectMatchReview.self, from: data)
                guard review.decision == .accepted, recording.canonicalID == review.canonicalID else { return nil }
                var current = true
                do { try validateEvidence(database, review: review) }
                catch ProjectRefinementError.staleEvidence { current = false }
                return ConfirmedProjectMatch(review: review, evidenceIsCurrent: current)
            }
        }
    }

    /// The UI retains one operation ID per tap intent. Replays return the same
    /// receipt; they never reapply an undone or superseded decision.
    func decideProjectMatch(id: UUID, expectedVersion: UUID, decision: ProjectReviewDecision, operationID: UUID) async throws -> ProjectReviewReceipt {
        guard decision != .pending else { throw ProjectRefinementError.invalidEvidence }
        return try await db.write { database in
            if let data = try Data.fetchOne(database, sql: "SELECT payload FROM project_review_events WHERE operation_id = ?", arguments: [operationID.uuidString]) {
                let event = try JSONDecoder().decode(ProjectReviewEvent.self, from: data)
                guard event.before.id == id, event.before.version == expectedVersion, event.after.decision == decision else { throw ProjectRefinementError.operationMismatch }
                return event.receipt
            }
            let before = try loadReview(database, id: id)
            guard before.version == expectedVersion else { throw ProjectRefinementError.conflict }
            guard let recording = try Recording.fetchOne(database, key: before.recordingID),
                  recording.deletedAt == nil, recording.canonicalID == before.canonicalID else { throw ProjectRefinementError.missing }
            // Reject/unsure may dismiss the original stale hypothesis. Accept
            // must still prove that the evidence shown is current.
            if decision == .accepted { try validateEvidence(database, review: before) }
            var after = before
            after.decision = decision
            after.version = UUID()
            let receipt = ProjectReviewReceipt(operationID: operationID, reviewID: id, decision: decision,
                newlyLinkedRecordings: decision == .accepted && before.decision != .accepted ? 1 : 0)
            try saveReview(database, review: after)
            let event = ProjectReviewEvent(before: before, after: after, receipt: receipt)
            try database.execute(sql: "INSERT INTO project_review_events(operation_id, review_id, payload) VALUES (?, ?, ?)",
                arguments: [operationID.uuidString, id.uuidString, try JSONEncoder().encode(event)])
            return receipt
        }
    }

    /// Returns the number of links actually removed (0 or 1). A later decision
    /// prevents undo rather than being overwritten. A fresh version prevents ABA.
    func undoProjectMatch(operationID: UUID) async throws -> Int {
        try await db.write { database in
            guard let row = try Row.fetchOne(database, sql: "SELECT payload, undone FROM project_review_events WHERE operation_id = ?", arguments: [operationID.uuidString]) else { throw ProjectRefinementError.missing }
            let undone: Int = row["undone"]
            if undone == 1 { return 0 }
            let data: Data = row["payload"]
            let event = try JSONDecoder().decode(ProjectReviewEvent.self, from: data)
            let current = try loadReview(database, id: event.after.id)
            guard current.version == event.after.version else { throw ProjectRefinementError.conflict }
            guard let recording = try Recording.fetchOne(database, key: current.recordingID),
                  recording.deletedAt == nil, recording.canonicalID == current.canonicalID else { throw ProjectRefinementError.missing }
            // Restore the human assignment, not the freshness of its evidence.
            let currentLinkWasProjected = current.decision == .accepted
            var restored = event.before
            restored.version = UUID()
            try saveReview(database, review: restored)
            try database.execute(sql: "UPDATE project_review_events SET undone = 1 WHERE operation_id = ?", arguments: [operationID.uuidString])
            return currentLinkWasProjected && restored.decision != .accepted ? 1 : 0
        }
    }
}
