import Foundation
import GRDB
import HarcDomain

/// One explicitly chosen original transcript; no lexical index or chunker.
/// Constructors stay inside Store so callers cannot rebind source provenance.
public struct ProjectEvidenceSnapshot: Sendable {
    public let transcript: String
    public let project: KnowledgeProject
    fileprivate let host: LibraryMetadata
    fileprivate let recording: Recording
    fileprivate let digest: String
}

public struct VerifiedProjectEvidence: Sendable {
    public let quote: String
    /// Original transcript UTF-8 byte offsets, never playback timestamps.
    public let startUTF8: Int
    public let endUTF8: Int
    fileprivate let snapshot: ProjectEvidenceSnapshot
    fileprivate let modelID: String
}

public enum ProjectEvidenceResponse: Sendable {
    case abstain
    case candidate(VerifiedProjectEvidence)
}

public enum ProjectEvidenceContractError: Error, Equatable {
    case invalidBrief, oversizedSource, invalidResponse, ambiguousQuote
}

public extension RecordingStore {
    /// Explicit owner edit with CAS. Editing the brief versions the project,
    /// making pending prior evidence stale without removing human assignments.
    func updateKnowledgeProjectBrief(id: UUID, expectedVersion: UUID, brief: String,
                                     expectedHost: LibraryMetadata) async throws -> KnowledgeProject {
        let brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty, brief.utf8.count <= 2_048 else { throw ProjectEvidenceContractError.invalidBrief }
        return try await db.write { database in
            try validateProjectReviewHost(database, expected: expectedHost)
            guard let data = try Data.fetchOne(database, sql: "SELECT payload FROM knowledge_projects WHERE id = ?", arguments: [id.uuidString]) else { throw ProjectRefinementError.missing }
            let old = try JSONDecoder().decode(KnowledgeProject.self, from: data)
            guard old.version == expectedVersion else { throw ProjectRefinementError.conflict }
            let updated = KnowledgeProject(id: old.id, name: old.name, version: UUID(), brief: brief)
            try database.execute(sql: "UPDATE knowledge_projects SET payload = ? WHERE id = ?", arguments: [try JSONEncoder().encode(updated), id.uuidString])
            return updated
        }
    }

    /// Fail rather than silently truncate a source/model context. Caller must
    /// obtain explicit consent for this canonical source and project version.
    func projectEvidenceSnapshot(recordingID: Int64, canonicalID: CanonicalRecordingID,
        projectID: UUID, projectVersion: UUID, expectedHost: LibraryMetadata) async throws -> ProjectEvidenceSnapshot {
        try Task.checkCancellation()
        return try await db.read { database in
            try validateProjectReviewHost(database, expected: expectedHost)
            guard let count = try Int.fetchOne(database,
                sql: "SELECT length(CAST(transcript_text AS BLOB)) FROM recordings WHERE id = ? AND deleted_at IS NULL", arguments: [recordingID]) else { throw ProjectRefinementError.missing }
            guard count <= 32_768 else { throw ProjectEvidenceContractError.oversizedSource }
            guard let recording = try Recording.fetchOne(database, key: recordingID),
                  recording.canonicalID == canonicalID, recording.deletedAt == nil,
                  let text = recording.transcriptText, !text.isEmpty,
                  let data = try Data.fetchOne(database, sql: "SELECT payload FROM knowledge_projects WHERE id = ?", arguments: [projectID.uuidString]) else { throw ProjectRefinementError.missing }
            let project = try JSONDecoder().decode(KnowledgeProject.self, from: data)
            guard project.version == projectVersion else { throw ProjectRefinementError.staleEvidence }
            guard let brief = project.brief, !brief.isEmpty, brief.utf8.count <= 2_048 else { throw ProjectEvidenceContractError.invalidBrief }
            return ProjectEvidenceSnapshot(transcript: text, project: project, host: expectedHost,
                recording: recording, digest: transcriptDigest(text))
        }
    }

    /// Strict fake/model response boundary. A valid span proves source presence,
    /// NOT semantic correctness; every candidate still requires human review.
    nonisolated static func validateProjectEvidenceResponse(_ raw: String,
        snapshot: ProjectEvidenceSnapshot, modelID: String) throws -> ProjectEvidenceResponse {
        guard raw.utf8.count <= 4_096, !modelID.isEmpty, modelID.utf8.count <= 120,
              uniqueTopLevelEvidenceKeys(Data(raw.utf8)),
              let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let decision = object["decision"] as? String else { throw ProjectEvidenceContractError.invalidResponse }
        if decision == "abstain", Set(object.keys) == ["decision"] { return .abstain }
        guard decision == "suggest", Set(object.keys) == ["decision", "quote"],
              let quote = object["quote"] as? String, quote.count >= 12, quote.utf8.count <= 2_048,
              !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectEvidenceContractError.invalidResponse
        }
        let source = Data(snapshot.transcript.utf8), needle = Data(quote.utf8)
        guard let range = source.range(of: needle) else { throw ProjectEvidenceContractError.invalidResponse }
        if source.range(of: needle, in: (range.lowerBound + 1)..<source.count) != nil {
            throw ProjectEvidenceContractError.ambiguousQuote
        }
        return .candidate(VerifiedProjectEvidence(quote: quote, startUTF8: range.lowerBound,
            endUTF8: range.upperBound, snapshot: snapshot, modelID: modelID))
    }
}


// Foundation accepts duplicate JSON object keys. Reject them rather than let
// one model declaration silently override another. Strings/escaped keys are
// decoded as JSON, so whitespace or Unicode escapes cannot evade the check.
private func uniqueTopLevelEvidenceKeys(_ data: Data) -> Bool {
    let bytes = Array(data)
    var index = 0, depth = 0
    var keys = Set<String>()
    while index < bytes.count {
        let byte = bytes[index]
        if byte == 34 {
            let start = index
            index += 1
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 34 { break }
                index += 1
            }
            guard index < bytes.count else { return false }
            let end = index
            index += 1
            if depth == 1 {
                var next = index
                while next < bytes.count && [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == 58 {
                    guard let key = try? JSONDecoder().decode(String.self, from: Data(bytes[start...end])),
                          keys.insert(key).inserted else { return false }
                }
            }
            continue
        }
        if byte == 123 || byte == 91 { depth += 1 }
        if byte == 125 || byte == 93 { depth -= 1 }
        index += 1
    }
    return true
}

/// Opaque captured selection identity, not a proof that the database is still
/// current. Future confirmation must revalidate its source/Host transactionally.
public struct ProjectPreviewSelectionKey: Equatable, Sendable {
    fileprivate let recordingID: Int64?
    fileprivate let canonicalID: CanonicalRecordingID
    fileprivate let projectID: UUID
    fileprivate let projectVersion: UUID
    fileprivate let transcriptDigest: String
    fileprivate let host: LibraryMetadata

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.recordingID == rhs.recordingID && lhs.canonicalID == rhs.canonicalID &&
        lhs.projectID == rhs.projectID && lhs.projectVersion == rhs.projectVersion &&
        lhs.transcriptDigest == rhs.transcriptDigest &&
        lhs.host.writerMode == rhs.host.writerMode && lhs.host.libraryID == rhs.host.libraryID &&
        lhs.host.hostAuthorityID == rhs.host.hostAuthorityID && lhs.host.hostStateID == rhs.host.hostStateID
    }
}

public extension ProjectEvidenceSnapshot {
    var previewSelectionKey: ProjectPreviewSelectionKey {
        ProjectPreviewSelectionKey(recordingID: recording.id, canonicalID: recording.canonicalID,
            projectID: project.id, projectVersion: project.version, transcriptDigest: digest, host: host)
    }
}

public extension RecordingStore {
    /// Read-only freshness check; future confirmation still requires an atomic
    /// transaction. A true result can become stale immediately after returning.
    func projectPreviewIsCurrent(_ snapshot: ProjectEvidenceSnapshot) async throws -> Bool {
        try await db.read { database in
            do { try validateProjectReviewHost(database, expected: snapshot.host) }
            catch { return false }
            guard let count = try Int.fetchOne(database,
                sql: "SELECT length(CAST(transcript_text AS BLOB)) FROM recordings WHERE id = ? AND deleted_at IS NULL",
                arguments: [snapshot.recording.id]), count <= 32_768,
                let recording = try Recording.fetchOne(database, key: snapshot.recording.id),
                recording.canonicalID == snapshot.recording.canonicalID, recording.deletedAt == nil,
                let text = recording.transcriptText, transcriptDigest(text) == snapshot.digest,
                let data = try Data.fetchOne(database, sql: "SELECT payload FROM knowledge_projects WHERE id = ?",
                    arguments: [snapshot.project.id.uuidString]) else { return false }
            return try JSONDecoder().decode(KnowledgeProject.self, from: data) == snapshot.project
        }
    }

    /// Registers synchronously on the DB writer queue before returning. Does not
    /// fetch transcript content or mutate the database. Observe before reading a
    /// fresh snapshot, so a transaction cannot fall in a read/subscribe gap.
    func observeProjectPreviewChanges(recordingID: Int64, projectID: UUID) -> ProjectPreviewChangeObservation {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observation = DatabaseRegionObservation(tracking:
            SQLRequest<Row>(sql: "SELECT canonical_uuid, transcript_text, deleted_at FROM recordings WHERE id = ?", arguments: [recordingID]),
            SQLRequest<Row>(sql: "SELECT payload FROM knowledge_projects WHERE id = ?", arguments: [projectID.uuidString]),
            SQLRequest<Row>(sql: "SELECT library_uuid, writer_mode, host_authority_id, host_state_uuid FROM library_metadata WHERE id = 1"))
        nonisolated(unsafe) let cancellable = observation.start(in: uncoordinatedDB,
            onError: { _ in continuation.yield(()); continuation.finish() },
            onChange: { _ in continuation.yield(()); continuation.finish() })
        continuation.onTermination = { _ in cancellable.cancel() }
        return ProjectPreviewChangeObservation(changes: stream, cancel: { cancellable.cancel(); continuation.finish() })
    }
}

/// Ownership of registration is explicit even if the stream is never consumed.
/// GRDB's cancellable is thread-safe. Cancellation is idempotent, no callbacks
/// or source values are exposed beyond a single invalidation signal.
public final class ProjectPreviewChangeObservation: @unchecked Sendable {
    public let changes: AsyncStream<Void>
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?
    init(changes: AsyncStream<Void>, cancel: @escaping @Sendable () -> Void) {
        self.changes = changes; cancellation = cancel
    }
    public func cancel() {
        let action = lock.withLock { let value = cancellation; cancellation = nil; return value }
        action?()
    }
    deinit { cancel() }
}
