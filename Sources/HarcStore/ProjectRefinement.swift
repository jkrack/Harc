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

public struct ProjectReviewApplication: Sendable {
    public let receipt: ProjectReviewReceipt
    public let didApply: Bool
}

public struct ProjectReviewCard: Sendable, Identifiable {
    public var id: UUID { review.id }
    public let review: ProjectMatchReview
    public let recordingTitle: String
    public let projectName: String
    public let sourceContext: String?
    public let evidenceIsCurrent: Bool
}

public struct ProjectReviewHistoryItem: Sendable {
    public let receipt: ProjectReviewReceipt
    public let projectName: String
    public let recordingTitle: String
    public let undone: Bool
    public let canUndo: Bool
}

public enum ProjectRefinementError: Error, Equatable {
    case missing, invalidEvidence, staleEvidence, conflict, operationMismatch, hostUnavailable
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
        migrator.registerMigration("v35_project_review_queue_index") { db in
            try db.execute(sql: """
                CREATE INDEX project_match_review_decision ON project_match_reviews(
                    json_extract(CAST(payload AS TEXT), '$.decision'), id
                )
                """)
        }
    }
}

// Additional UI session binding, on top of StoreDatabaseAccess's live writer
// lease validation. A former Host becoming standalone must not retain UI writes.
private func validateProjectReviewHost(_ db: Database, expected: LibraryMetadata?) throws {
    guard let expected else { return }
    let current = try RecordingStore.readLibraryMetadata(in: db)
    guard expected.writerMode == .host, current.writerMode == .host,
          expected.libraryID == current.libraryID,
          expected.hostAuthorityID == current.hostAuthorityID,
          expected.hostStateID == current.hostStateID else {
        throw ProjectRefinementError.hostUnavailable
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

    /// Bounded local review snapshot. Never returns trashed recordings or
    /// resolved/unsure decisions. No filesystem reads or inferred timestamps.
    func pendingProjectReviewCards(limit: Int = 3, deferred: Bool = false, afterReviewID: UUID? = nil) async throws -> [ProjectReviewCard] {
        let limit = min(max(limit, 1), 20)
        return try await db.read { database in
            let data = try Data.fetchAll(database, sql: """
                SELECT m.payload FROM project_match_reviews m
                JOIN recordings r ON r.id = m.recording_id
                WHERE r.deleted_at IS NULL AND json_extract(CAST(m.payload AS TEXT), '$.decision') = ?
                AND (? IS NULL OR m.id > ?)
                ORDER BY m.id LIMIT ?
                """, arguments: [deferred ? "unsure" : "pending", afterReviewID?.uuidString, afterReviewID?.uuidString, limit])
            return try data.map { data in
                let review = try JSONDecoder().decode(ProjectMatchReview.self, from: data)
                guard let recording = try Recording.fetchOne(database, key: review.recordingID),
                      let projectData = try Data.fetchOne(database, sql: "SELECT payload FROM knowledge_projects WHERE id = ?", arguments: [review.project.id.uuidString]) else { throw ProjectRefinementError.missing }
                let project = try JSONDecoder().decode(KnowledgeProject.self, from: projectData)
                var current = true
                do { try validateEvidence(database, review: review) }
                catch ProjectRefinementError.staleEvidence { current = false }
                let context: String?
                if let text = recording.transcriptText, let range = text.range(of: review.quote) {
                    let start = text.index(range.lowerBound, offsetBy: -160, limitedBy: text.startIndex) ?? text.startIndex
                    let end = text.index(range.upperBound, offsetBy: 160, limitedBy: text.endIndex) ?? text.endIndex
                    context = String(text[start..<end])
                } else { context = nil }
                return ProjectReviewCard(review: review, recordingTitle: recording.title ?? "Untitled recording",
                    projectName: project.name, sourceContext: context, evidenceIsCurrent: current)
            }
        }
    }

    /// Explicitly reopens a pending or set-aside hypothesis when its original verbatim
    /// quote still exists. It cannot manufacture new supporting text or erase a
    /// accepted/rejected answer. Prior set-aside event history remains intact.
    /// The caller must display the refreshed card before acceptance.
    func refreshPendingProjectReview(id: UUID, expectedVersion: UUID, expectedHost: LibraryMetadata? = nil) async throws {
        try await db.write { database in
            try validateProjectReviewHost(database, expected: expectedHost)
            let old = try loadReview(database, id: id)
            guard old.version == expectedVersion, old.decision == .pending || old.decision == .unsure else { throw ProjectRefinementError.conflict }
            guard let recording = try Recording.fetchOne(database, key: old.recordingID), recording.deletedAt == nil,
                  recording.canonicalID == old.canonicalID,
                  let text = recording.transcriptText, text.contains(old.quote),
                  let data = try Data.fetchOne(database, sql: "SELECT payload FROM knowledge_projects WHERE id = ?", arguments: [old.project.id.uuidString]) else { throw ProjectRefinementError.invalidEvidence }
            let project = try JSONDecoder().decode(KnowledgeProject.self, from: data)
            let updated = ProjectMatchReview(id: old.id, recordingID: old.recordingID, canonicalID: old.canonicalID,
                project: project, recordingRevision: recording.revision, transcriptSHA256: transcriptDigest(text),
                quote: old.quote, generatorID: old.generatorID, decision: .pending, version: UUID())
            try saveReview(database, review: updated)
        }
    }

    /// Durable undo-history presentation. Deleted/trashed sources remain hidden.
    /// The newest 20 events are bounded; old conflicting events are inspectable
    /// but never offered as undoable. This does not replay committed effects.
    func recentProjectReviewHistory(limit: Int = 20) async throws -> [ProjectReviewHistoryItem] {
        try await db.read { database in
            let rows = try Row.fetchAll(database, sql: """
                SELECT e.payload AS event_payload, e.undone AS undone, m.payload AS review_payload,
                       p.payload AS project_payload, r.title AS recording_title, r.canonical_uuid AS canonical_uuid
                FROM project_review_events e JOIN project_match_reviews m ON m.id = e.review_id
                JOIN recordings r ON r.id = m.recording_id
                JOIN knowledge_projects p ON p.id = m.project_id
                WHERE r.deleted_at IS NULL ORDER BY e.rowid DESC LIMIT ?
                """, arguments: [min(max(limit, 1), 100)])
            return try rows.map { row in
                let event = try JSONDecoder().decode(ProjectReviewEvent.self, from: row["event_payload"] as Data)
                let review = try JSONDecoder().decode(ProjectMatchReview.self, from: row["review_payload"] as Data)
                let project = try JSONDecoder().decode(KnowledgeProject.self, from: row["project_payload"] as Data)
                let undone = (row["undone"] as Int) == 1
                return ProjectReviewHistoryItem(receipt: event.receipt, projectName: project.name,
                    recordingTitle: (row["recording_title"] as String?) ?? "Untitled recording", undone: undone,
                    canUndo: !undone && review.version == event.after.version)
            }
        }
    }

    /// The UI retains one operation ID per tap intent. Replays return the same
    /// receipt; they never reapply an undone or superseded decision.
    func decideProjectMatch(id: UUID, expectedVersion: UUID, decision: ProjectReviewDecision, operationID: UUID) async throws -> ProjectReviewReceipt {
        try await applyProjectMatchDecision(id: id, expectedVersion: expectedVersion, decision: decision, operationID: operationID).receipt
    }

    func applyProjectMatchDecision(id: UUID, expectedVersion: UUID, decision: ProjectReviewDecision, operationID: UUID, expectedHost: LibraryMetadata? = nil) async throws -> ProjectReviewApplication {
        guard decision != .pending else { throw ProjectRefinementError.invalidEvidence }
        return try await db.write { database in
            try validateProjectReviewHost(database, expected: expectedHost)
            if let data = try Data.fetchOne(database, sql: "SELECT payload FROM project_review_events WHERE operation_id = ?", arguments: [operationID.uuidString]) {
                let event = try JSONDecoder().decode(ProjectReviewEvent.self, from: data)
                guard event.before.id == id, event.before.version == expectedVersion, event.after.decision == decision else { throw ProjectRefinementError.operationMismatch }
                return ProjectReviewApplication(receipt: event.receipt, didApply: false)
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
            return ProjectReviewApplication(receipt: receipt, didApply: true)
        }
    }

    /// Returns the number of links actually removed (0 or 1). A later decision
    /// prevents undo rather than being overwritten. A fresh version prevents ABA.
    func undoProjectMatch(operationID: UUID, expectedHost: LibraryMetadata? = nil) async throws -> Int {
        try await db.write { database in
            try validateProjectReviewHost(database, expected: expectedHost)
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
