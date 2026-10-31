import CryptoKit
import Foundation
import GRDB
import HarcDomain

public extension RecordingStore {
    /// Retains immutable evidence without making it current or enrolled. Callers
    /// must separately authenticate the producer and validate artifact membership
    /// before any display/confirmation authority is granted to this evidence.
    @discardableResult
    func retainSpeakerEvidence(_ evidence: SpeakerEvidenceSnapshot, at date: Date = Date()) async throws -> Data {
        try await db.write { database in
            try Self.retainSpeakerEvidence(in: database, evidence: evidence, at: date)
        }
    }

    @discardableResult
    internal static func retainSpeakerEvidence(in database: Database,
        evidence: SpeakerEvidenceSnapshot, at date: Date) throws -> Data {
        guard date.timeIntervalSince1970.isFinite else {
            throw StoreError.invalidData("Speaker evidence retention time is invalid")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(evidence)
        guard bytes.count <= 16_384 else {
            throw StoreError.invalidData("Speaker evidence snapshot exceeds its storage bound")
        }
        let digest = evidence.evidenceSHA256
        guard let recording = try Recording
            .filter(Recording.Columns.canonicalID == evidence.canonicalRecordingID.description)
            .fetchOne(database), let recordingID = recording.id, recording.deletedAt == nil else {
            throw StoreError.notFound
        }
        guard recording.canonicalPCMHash == evidence.canonicalPCMHash else {
            throw StoreError.canonicalArtifactIdentityMismatch
        }
        if let existing = try Row.fetchOne(database, sql:
            "SELECT recording_id, snapshot_json FROM speaker_evidence_snapshots WHERE evidence_sha256 = ?",
            arguments: [digest]) {
            let existingBytes: Data = existing["snapshot_json"]
            guard existing["recording_id"] as Int64 == recordingID,
                  try Self.decodeSpeakerEvidence(existingBytes, expectedDigest: digest) == evidence else {
                throw StoreError.invalidData("Speaker evidence identity was reused")
            }
            return digest
        }
        try database.execute(sql: """
            INSERT INTO speaker_evidence_snapshots(evidence_sha256, recording_id, snapshot_json, retained_at)
            VALUES (?, ?, ?, ?)
            """, arguments: [digest, recordingID, bytes, date.timeIntervalSince1970])
        return digest
    }

    /// Reads provenance, including superseded evidence. Presence is not approval
    /// to use it as a current cluster or recognition-pack prototype.
    func retainedSpeakerEvidence(sha256: Data) async throws -> SpeakerEvidenceSnapshot? {
        guard sha256.count == 32 else {
            throw StoreError.invalidData("Speaker evidence identity must contain 32 bytes")
        }
        return try await db.read { database in
            guard let bytes = try Data.fetchOne(database, sql:
                "SELECT snapshot_json FROM speaker_evidence_snapshots WHERE evidence_sha256 = ?",
                arguments: [sha256]) else { return nil }
            return try Self.decodeSpeakerEvidence(bytes, expectedDigest: sha256)
        }
    }

    internal static func decodeSpeakerEvidence(_ bytes: Data, expectedDigest: Data) throws -> SpeakerEvidenceSnapshot {
        guard bytes.count <= 16_384 else {
            throw StoreError.invalidData("Stored speaker evidence exceeds its storage bound")
        }
        let evidence = try JSONDecoder().decode(SpeakerEvidenceSnapshot.self, from: bytes)
        guard evidence.evidenceSHA256 == expectedDigest else {
            throw StoreError.invalidData("Stored speaker evidence digest does not match its payload")
        }
        return evidence
    }
}

public extension RecordingStore {
    /// Explicit selection of exact retained evidence, not a recording/index lookup.
    /// Call only after review of that evidence and validated artifact membership.
    /// A correction must present its review token, including after an A-B-A reassignment.
    @discardableResult
    func confirmSpeakerEvidence(sha256: Data, personID: Int64, replacing expectedToken: UUID? = nil,
                                at date: Date = Date()) async throws -> UUID {
        guard sha256.count == 32, date.timeIntervalSince1970.isFinite else {
            throw StoreError.invalidData("Invalid speaker evidence confirmation")
        }
        return try await db.write { database in
            try Self.confirmSpeakerEvidence(in: database, sha256: sha256, personID: personID,
                expectedToken: expectedToken, date: date)

        }
    }

    func speakerEvidenceAssignment(sha256: Data) async throws -> (personID: Int64, token: UUID)? {
        guard sha256.count == 32 else { throw StoreError.invalidData("Invalid speaker evidence digest") }
        return try await db.read { try Self.speakerEvidenceAssignment(in: $0, sha256: sha256) }
    }

    /// Withdraws enrollment while retaining exact evidence for provenance.
    func unconfirmSpeakerEvidence(sha256: Data, expectedToken: UUID) async throws {
        guard sha256.count == 32 else { throw StoreError.invalidData("Invalid speaker evidence digest") }
        try await db.write { database in
            guard let previous = try Self.speakerEvidenceAssignment(in: database, sha256: sha256) else { return }
            guard previous.token == expectedToken else {
                throw StoreError.invalidData("Speaker evidence confirmation changed since review")
            }
            try database.execute(sql: "DELETE FROM confirmed_speaker_evidence WHERE evidence_sha256 = ?", arguments: [sha256])
            _ = try Self.bumpSpeakerProfiles(in: database, personIDs: [previous.personID], at: Date().timeIntervalSince1970)
        }
    }
}

extension RecordingStore {
    private static func confirmSpeakerEvidence(in database: Database, sha256: Data, personID: Int64,
                                              expectedToken: UUID?, date: Date) throws -> UUID {
            guard try Int64.fetchOne(database, sql: "SELECT id FROM people WHERE id = ?", arguments: [personID]) != nil else { throw StoreError.notFound }
            guard let row = try Row.fetchOne(database, sql: """
                SELECT e.recording_id, e.snapshot_json FROM speaker_evidence_snapshots e
                JOIN recordings r ON r.id = e.recording_id
                WHERE e.evidence_sha256 = ? AND r.deleted_at IS NULL
                """, arguments: [sha256]) else { throw StoreError.notFound }
            _ = try Self.decodeSpeakerEvidence(row["snapshot_json"], expectedDigest: sha256)
            let previous = try Self.speakerEvidenceAssignment(in: database, sha256: sha256)
            if let previous, previous.personID == personID { return previous.token }
            guard previous?.token == expectedToken else {
                throw StoreError.invalidData("Speaker evidence confirmation changed since review")
            }
            let token = UUID()
            try database.execute(sql: """
                INSERT INTO confirmed_speaker_evidence(evidence_sha256, person_id, prototype_uuid, confirmed_at, confirmation_uuid)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(evidence_sha256) DO UPDATE SET person_id = excluded.person_id,
                    confirmed_at = excluded.confirmed_at, confirmation_uuid = excluded.confirmation_uuid
                """, arguments: [sha256, personID, SpeakerPrototypeID.random().description,
                    date.timeIntervalSince1970, token.uuidString.lowercased()])
            let recordingID: Int64 = row["recording_id"]
            try database.execute(sql: "INSERT OR IGNORE INTO bound_speaker_enrollment_sources(recording_id) VALUES (?)",
                arguments: [recordingID])
            var affectedPeople = Set([previous?.personID, personID].compactMap { $0 })
            if database.changesCount > 0 {
                // This source has crossed to exact evidence. Preserve its labels
                // and links as history, but never re-enroll their mutable payloads.
                affectedPeople.formUnion(try Int64.fetchAll(database, sql:
                    "SELECT DISTINCT person_id FROM person_speakers WHERE recording_id = ? AND is_user_confirmed = 1",
                    arguments: [recordingID]))
            }
            _ = try Self.bumpSpeakerProfiles(in: database,
                personIDs: affectedPeople, at: date.timeIntervalSince1970)
            return token
    }

    private static func speakerEvidenceAssignment(in database: Database, sha256: Data) throws -> (personID: Int64, token: UUID)? {
        guard let row = try Row.fetchOne(database, sql:
            "SELECT person_id, confirmation_uuid FROM confirmed_speaker_evidence WHERE evidence_sha256 = ?", arguments: [sha256]) else { return nil }
        guard let token = UUID(uuidString: row["confirmation_uuid"]) else {
            throw StoreError.invalidData("Invalid stored speaker confirmation token")
        }
        return (row["person_id"], token)
    }

    struct ConfirmedSpeakerEvidence {
        let personID: Int64
        let recordingID: Int64
        let prototypeID: SpeakerPrototypeID
        let snapshot: SpeakerEvidenceSnapshot
    }

    /// Shared confirmed-snapshot selection for packs and authoritative matching.
    static func confirmedSpeakerEvidence(in database: Database, modelID: String, dimensions: UInt32,
                                         excludingRecordingID: Int64? = nil) throws -> [ConfirmedSpeakerEvidence] {
        let rows = try Row.fetchAll(database, sql: """
            SELECT c.person_id, c.prototype_uuid, e.recording_id, e.evidence_sha256, e.snapshot_json
            FROM confirmed_speaker_evidence c
            JOIN speaker_evidence_snapshots e ON e.evidence_sha256 = c.evidence_sha256
            JOIN recordings r ON r.id = e.recording_id
            WHERE r.deleted_at IS NULL AND (? IS NULL OR r.id != ?)
            """, arguments: [excludingRecordingID, excludingRecordingID])
        return try rows.compactMap { row in
            let snapshot = try decodeSpeakerEvidence(row["snapshot_json"], expectedDigest: row["evidence_sha256"])
            guard snapshot.modelID == modelID, snapshot.embedding.dimensions == dimensions,
                  snapshot.speechDurationMs >= SpeakerRecognitionMatcher.minimumEnrollmentSpeechMs,
                  snapshot.speechDurationMs <= UInt64(Int.max),
                  let uuid = UUID(uuidString: row["prototype_uuid"]) else { return nil }
            return ConfirmedSpeakerEvidence(personID: row["person_id"], recordingID: row["recording_id"],
                prototypeID: SpeakerPrototypeID(uuid), snapshot: snapshot)
        }
    }
}

public extension RecordingStore {
    /// Resolves a published Host slot to exact retained evidence. A retained but
    /// unpublished artifact, a changed sidecar, and work in progress cannot qualify.
    func currentHostSpeakerEvidence(recordingID: Int64, speakerIndex: Int) async throws -> SpeakerEvidenceSnapshot? {
        try await db.read { try Self.currentHostSpeakerEvidence(in: $0, recordingID: recordingID, speakerIndex: speakerIndex) }
    }

    /// An opaque review of both the current voice evidence and its displayed assignment.
    /// Fetch again after any rejected mutation; callers cannot manufacture review authority.
    struct HostSpeakerReview: Sendable, Equatable {
        public let evidence: SpeakerEvidenceSnapshot
        fileprivate let recordingID: Int64
        fileprivate let speakerIndex: Int
        fileprivate let revision: EntityRevision
        fileprivate let linkedPersonID: Int64?
        fileprivate let linkedAt: Double?
        fileprivate let userConfirmed: Int?
        fileprivate let displayName: String?
        fileprivate let selectionToken: UUID?
        fileprivate let pendingSuggestions: [PendingSuggestion]
    }

    func currentHostSpeakerReview(recordingID: Int64, speakerIndex: Int) async throws -> HostSpeakerReview? {
        try await db.read { try Self.hostSpeakerReview(in: $0, recordingID: recordingID, speakerIndex: speakerIndex) }
    }

    /// Loads direct-edit review authority without allowing an unavailable bound
    /// artifact to masquerade as a legacy source.
    func hostSpeakerReviewForEditing(recordingID: Int64, speakerIndex: Int) async throws -> HostSpeakerReview? {
        try await db.read { database in
            if let review = try Self.hostSpeakerReview(in: database, recordingID: recordingID, speakerIndex: speakerIndex) {
                return review
            }
            guard try !Self.requiresBoundSpeakerReview(in: database, recordingID: recordingID) else {
                throw StoreError.invalidData("Current voice evidence is unavailable. Wait for processing before changing this speaker.")
            }
            return nil
        }
    }

    /// Removes only the reviewed current voice enrollment and its visible assignment.
    /// Retained evidence and the permanent legacy-enrollment exclusion survive.
    func unlinkHostSpeakerReview(_ review: HostSpeakerReview) async throws {
        try await db.write { database in
            guard try Self.hostSpeakerReview(in: database, recordingID: review.recordingID,
                speakerIndex: review.speakerIndex) == review,
                let recording = try Recording.fetchOne(database, key: review.recordingID) else {
                throw StoreError.invalidData("The speaker assignment changed since review")
            }
            let previous = try Self.speakerEvidenceAssignment(in: database, sha256: review.evidence.evidenceSHA256)
            let now = Date()
            try database.execute(sql: "DELETE FROM confirmed_speaker_evidence WHERE evidence_sha256 = ?",
                arguments: [review.evidence.evidenceSHA256])
            try database.execute(sql: "DELETE FROM person_speakers WHERE recording_id = ? AND speaker_index = ?",
                arguments: [review.recordingID, review.speakerIndex])
            try database.execute(sql: "DELETE FROM pending_suggestions WHERE recording_id = ? AND speaker_index = ?",
                arguments: [review.recordingID, review.speakerIndex])
            var names = recording.speakerNames
            names.removeValue(forKey: review.speakerIndex)
            let encoded = Dictionary(uniqueKeysWithValues: names.map { (String($0.key), $0.value) })
            let json = String(data: try JSONEncoder().encode(encoded), encoding: .utf8)
            try database.execute(sql: "UPDATE recordings SET speaker_names = ?, updated_at = ? WHERE id = ?",
                arguments: [json, now, review.recordingID])
            _ = try Self.bumpSpeakerProfiles(in: database,
                personIDs: Set([previous?.personID, review.linkedPersonID].compactMap { $0 }),
                at: now.timeIntervalSince1970)
            _ = try Self.bumpRevisionAndAppendLibraryChange(in: database,
                recordingID: review.recordingID, changedAt: now)
        }
        await reprojectOKF(id: review.recordingID)
    }

    /// Loads authority for the exact suggestion shown by a review screen.
    /// Nil is allowed only for a source that has never acquired bound evidence.
    func hostSpeakerReview(for suggestion: PendingSuggestion) async throws -> HostSpeakerReview? {
        try await db.read { database in
            if let review = try Self.hostSpeakerReview(in: database,
                recordingID: suggestion.recordingID, speakerIndex: suggestion.speakerIndex) {
                guard review.pendingSuggestions.contains(suggestion) else {
                    throw StoreError.invalidData("The speaker suggestion changed since review")
                }
                return review
            }
            guard try !Self.requiresBoundSpeakerReview(in: database, recordingID: suggestion.recordingID) else {
                throw StoreError.invalidData("Current voice evidence is unavailable. Wait for processing before confirming this speaker.")
            }
            return nil
        }
    }

    internal static func requiresBoundSpeakerReview(in database: Database, recordingID: Int64) throws -> Bool {
        try Bool.fetchOne(database, sql: """
            SELECT EXISTS(SELECT 1 FROM speaker_evidence_snapshots WHERE recording_id = ?)
                OR EXISTS(SELECT 1 FROM bound_speaker_enrollment_sources WHERE recording_id = ?)
                OR EXISTS(SELECT 1 FROM selected_speaker_cluster_map WHERE recording_id = ?)
            """, arguments: [recordingID, recordingID, recordingID]) == true
    }

    /// Commits the reviewed voice selection, person link and visible label together.
    /// Even a same-artifact legacy correction invalidates this review.
    func confirmHostSpeakerReview(_ review: HostSpeakerReview, personID: Int64) async throws {
        try await db.write { database in
            try Self.confirmHostSpeakerReview(in: database, review: review, personID: personID)
        }
        await reprojectOKF(id: review.recordingID)
    }

    /// Creating a new identity is part of the same transaction as its reviewed
    /// enrollment and label. A stale review or failed write cannot leave an orphan person.
    func createPersonForHostSpeakerReview(_ review: HostSpeakerReview, displayName: String) async throws -> Int64 {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError.invalidData("A person needs a name") }
        let personID = try await db.write { database in
            let now = Date().timeIntervalSince1970
            try database.execute(sql: """
                INSERT INTO people(stable_uuid, display_name, match_threshold, created_at, updated_at, profile_revision)
                VALUES (?, ?, NULL, ?, ?, 1)
                """, arguments: [PersonID.random().description, name, now, now])
            let personID = database.lastInsertedRowID
            try Self.confirmHostSpeakerReview(in: database, review: review, personID: personID)
            return personID
        }
        await reprojectOKF(id: review.recordingID)
        return personID
    }

    private static func confirmHostSpeakerReview(in database: Database, review: HostSpeakerReview,
                                                personID: Int64) throws {
            guard try Self.hostSpeakerReview(in: database, recordingID: review.recordingID,
                speakerIndex: review.speakerIndex) == review else {
                throw StoreError.invalidData("The speaker assignment changed since review")
            }
            guard let name = try String.fetchOne(database, sql: "SELECT display_name FROM people WHERE id = ?",
                    arguments: [personID]),
                  let recording = try Recording.fetchOne(database, key: review.recordingID) else { throw StoreError.notFound }
            let now = Date()
            _ = try Self.confirmSpeakerEvidence(in: database, sha256: review.evidence.evidenceSHA256,
                personID: personID, expectedToken: review.selectionToken, date: now)
            try database.execute(sql: """
                INSERT OR REPLACE INTO person_speakers
                    (person_id, recording_id, speaker_index, confirmed_at, is_user_confirmed)
                VALUES (?, ?, ?, ?, 1)
                """, arguments: [personID, review.recordingID, review.speakerIndex, now.timeIntervalSince1970])
            try database.execute(sql: "DELETE FROM pending_suggestions WHERE recording_id = ? AND speaker_index = ?",
                arguments: [review.recordingID, review.speakerIndex])
            try database.execute(sql: "DELETE FROM dismissed_suggestions WHERE person_id = ? AND recording_id = ? AND speaker_index = ?",
                arguments: [personID, review.recordingID, review.speakerIndex])
            var names = recording.speakerNames
            names[review.speakerIndex] = name
            let encoded = Dictionary(uniqueKeysWithValues: names.map { (String($0.key), $0.value) })
            let json = String(data: try JSONEncoder().encode(encoded), encoding: .utf8)
            try database.execute(sql: "UPDATE recordings SET speaker_names = ?, updated_at = ? WHERE id = ?",
                arguments: [json, now, review.recordingID])
            _ = try Self.bumpRevisionAndAppendLibraryChange(in: database,
                recordingID: review.recordingID, changedAt: now)
    }

    private static func hostSpeakerReview(in database: Database, recordingID: Int64,
                                         speakerIndex: Int) throws -> HostSpeakerReview? {
        guard let evidence = try currentHostSpeakerEvidence(in: database, recordingID: recordingID, speakerIndex: speakerIndex),
              let recording = try Recording.fetchOne(database, key: recordingID) else { return nil }
        let link = try Row.fetchOne(database, sql: """
            SELECT person_id, confirmed_at, is_user_confirmed FROM person_speakers
            WHERE recording_id = ? AND speaker_index = ?
            """, arguments: [recordingID, speakerIndex])
        return HostSpeakerReview(evidence: evidence, recordingID: recordingID, speakerIndex: speakerIndex,
            revision: recording.revision, linkedPersonID: link?["person_id"], linkedAt: link?["confirmed_at"],
            userConfirmed: link?["is_user_confirmed"], displayName: recording.speakerNames[speakerIndex],
            selectionToken: try speakerEvidenceAssignment(in: database, sha256: evidence.evidenceSHA256)?.token,
            pendingSuggestions: try Row.fetchAll(database, sql: """
                SELECT person_id, score, created_at FROM pending_suggestions
                WHERE recording_id = ? AND speaker_index = ? ORDER BY person_id
                """, arguments: [recordingID, speakerIndex]).map { row in
                    PendingSuggestion(personID: row["person_id"], recordingID: recordingID,
                        speakerIndex: speakerIndex, score: row["score"],
                        createdAt: Date(timeIntervalSince1970: row["created_at"]))
                })
    }

    @discardableResult
    func confirmCurrentHostSpeakerEvidence(recordingID: Int64, speakerIndex: Int,
        expectedEvidenceSHA256: Data, personID: Int64, replacing expectedToken: UUID? = nil) async throws -> UUID {
        try await db.write { database in
            guard let evidence = try Self.currentHostSpeakerEvidence(in: database,
                    recordingID: recordingID, speakerIndex: speakerIndex),
                  evidence.evidenceSHA256 == expectedEvidenceSHA256 else {
                throw StoreError.invalidData("The speaker artifact changed since review")
            }
            return try Self.confirmSpeakerEvidence(in: database, sha256: expectedEvidenceSHA256,
                personID: personID, expectedToken: expectedToken, date: Date())
        }
    }
}

extension RecordingStore {
    /// Called only by trusted local Host publication, in its ready-state transaction.
    static func installCurrentHostSpeakerEvidence(in database: Database, recording: Recording,
                                                  evidence: [Int: Data]) throws {
        guard let recordingID = recording.id else { throw StoreError.notFound }
        let previous = try Row.fetchAll(database, sql:
            "SELECT speaker_index, evidence_sha256 FROM current_speaker_evidence WHERE recording_id = ?",
            arguments: [recordingID])
        let sameEvidence = previous.count == evidence.count && previous.allSatisfy {
            evidence[$0["speaker_index"] as Int] == $0["evidence_sha256"] as Data
        }
        if !previous.isEmpty && !sameEvidence {
            // Identical words/turns do not prove identical voice evidence.
            // Retain old enrollment, but retire the old generation's labels.
            try Self.invalidateReplacedSpeakerAssignments(in: database, recording: recording,
                structuredTranscriptData: nil, text: recording.transcriptText ?? "", now: Date(),
                force: true, clearMutableEmbeddings: false)
        }
        try database.execute(sql: "DELETE FROM current_speaker_evidence WHERE recording_id = ?", arguments: [recordingID])
        guard !evidence.isEmpty else { return }
        guard let path = recording.jsonPath else { throw StoreError.invalidData("Missing Host speaker artifact") }
        let artifact = try speakerArtifactDigest(path: path)
        for (index, digest) in evidence {
            guard index >= 0, let row = try Row.fetchOne(database, sql:
                "SELECT recording_id, snapshot_json FROM speaker_evidence_snapshots WHERE evidence_sha256 = ?",
                arguments: [digest]), row["recording_id"] as Int64 == recordingID else {
                throw StoreError.invalidData("Host speaker evidence is not retained for this recording")
            }
            let snapshot = try decodeSpeakerEvidence(row["snapshot_json"], expectedDigest: digest)
            guard snapshot.canonicalRecordingID == recording.canonicalID,
                  snapshot.canonicalPCMHash == recording.canonicalPCMHash,
                  snapshot.processingArtifactSHA256 == artifact,
                  snapshot.localClusterID == "host-speaker-\(index)" else {
                throw StoreError.invalidData("Host speaker evidence does not match the staged artifact")
            }
            try database.execute(sql: "INSERT INTO current_speaker_evidence VALUES (?, ?, ?)",
                arguments: [recordingID, index, digest])
        }
    }

    private static func currentHostSpeakerEvidence(in database: Database, recordingID: Int64,
                                                   speakerIndex: Int) throws -> SpeakerEvidenceSnapshot? {
        guard let recording = try Recording.fetchOne(database, key: recordingID), recording.deletedAt == nil,
              recording.processing.state == .ready, recording.projection.state == .ready,
              let path = recording.jsonPath,
              let row = try Row.fetchOne(database, sql: """
                SELECT c.evidence_sha256, e.snapshot_json FROM current_speaker_evidence c
                JOIN speaker_evidence_snapshots e ON e.evidence_sha256 = c.evidence_sha256 AND e.recording_id = c.recording_id
                WHERE c.recording_id = ? AND c.speaker_index = ?
                """, arguments: [recordingID, speakerIndex]) else { return nil }
        let snapshot = try decodeSpeakerEvidence(row["snapshot_json"], expectedDigest: row["evidence_sha256"])
        if let map = try Self.selectedSpeakerClusterMap(in: database, recordingID: recordingID) {
            guard try map.canonicalSpeakerIndex(for: snapshot) == UInt32(exactly: speakerIndex) else {
                throw StoreError.invalidData("Published edge voice no longer maps to this speaker")
            }
            return snapshot
        }
        guard try Bool.fetchOne(database, sql:
            "SELECT EXISTS(SELECT 1 FROM bound_speaker_observation_provenance WHERE evidence_sha256 = ?)",
            arguments: [snapshot.evidenceSHA256]) != true else {
            throw StoreError.invalidData("Selected edge speaker mapping is unavailable")
        }
        guard snapshot.canonicalRecordingID == recording.canonicalID,
              snapshot.canonicalPCMHash == recording.canonicalPCMHash,
              ["host-speaker-\(speakerIndex)", "local-speaker-\(speakerIndex)"].contains(snapshot.localClusterID),
              snapshot.processingArtifactSHA256 == (try speakerArtifactDigest(path: path)) else {
            throw StoreError.invalidData("Published speaker evidence binding changed")
        }
        return snapshot
    }

    internal static func speakerArtifactDigest(path: String) throws -> Data {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        var hash = SHA256()
        while true {
            let count = try autoreleasepool {
                let bytes = try file.read(upToCount: 1_048_576) ?? Data()
                hash.update(data: bytes)
                return bytes.count
            }
            if count == 0 { break }
        }
        return Data(hash.finalize())
    }
}

public extension RecordingStore {
    /// Recognition input intentionally has no mutable speaker-slot identity.
    struct SpeakerRecognitionReference: Sendable {
        public let recordingID: Int64
        public let embedding: Data
    }

    func speakerRecognitionReferences(personID: Int64, modelID: String, dimensions: UInt32) async throws -> [SpeakerRecognitionReference] {
        try await db.read { database in
            let legacy = try Row.fetchAll(database, sql: """
                SELECT e.recording_id, e.embedding FROM speaker_embeddings e
                JOIN person_speakers ps ON ps.recording_id = e.recording_id AND ps.speaker_index = e.speaker_index
                JOIN recordings r ON r.id = e.recording_id
                WHERE ps.person_id = ? AND ps.is_user_confirmed = 1 AND e.embedder_kind = ?
                  AND e.total_ms >= ? AND e.segment_count > 0 AND r.deleted_at IS NULL
                  AND NOT EXISTS (SELECT 1 FROM bound_speaker_enrollment_sources b WHERE b.recording_id = e.recording_id)
                """, arguments: [personID, modelID, SpeakerRecognitionMatcher.minimumEnrollmentSpeechMs])
            var references = legacy.map { SpeakerRecognitionReference(recordingID: $0["recording_id"], embedding: $0["embedding"]) }
            for selected in try Self.confirmedSpeakerEvidence(in: database, modelID: modelID, dimensions: dimensions)
                where selected.personID == personID {
                references.append(SpeakerRecognitionReference(recordingID: selected.recordingID,
                    embedding: Self.encodeFloat32(selected.snapshot.embedding.dequantized)))
            }
            return references
        }
    }
}

public extension RecordingStore {
    struct EnrolledSpeakerEvidence: Sendable, Identifiable {
        public var id: Data { snapshot.evidenceSHA256 }
        public let snapshot: SpeakerEvidenceSnapshot
        public let recordingID: Int64
        public let recordingTitle: String
        fileprivate let personID: Int64
        fileprivate let token: UUID
    }

    /// Includes selected historical generations without fabricating a current slot.
    func enrolledSpeakerEvidence(personID: Int64) async throws -> [EnrolledSpeakerEvidence] {
        try await db.read { database in
            try Row.fetchAll(database, sql: """
                SELECT c.confirmation_uuid, e.snapshot_json, e.evidence_sha256, e.recording_id
                FROM confirmed_speaker_evidence c JOIN speaker_evidence_snapshots e ON e.evidence_sha256 = c.evidence_sha256
                JOIN recordings r ON r.id = e.recording_id
                WHERE c.person_id = ? AND r.deleted_at IS NULL ORDER BY e.recording_id, e.evidence_sha256
                """, arguments: [personID]).map { row in
                guard let token = UUID(uuidString: row["confirmation_uuid"]),
                      let recording = try Recording.fetchOne(database, key: row["recording_id"] as Int64) else {
                    throw StoreError.invalidData("Invalid selected speaker evidence")
                }
                return EnrolledSpeakerEvidence(snapshot: try Self.decodeSpeakerEvidence(row["snapshot_json"], expectedDigest: row["evidence_sha256"]),
                    recordingID: row["recording_id"], recordingTitle: recording.displayTitle, personID: personID, token: token)
            }
        }
    }

    /// Splits exact selected samples. All review tokens are checked before any
    /// write, and current labels move only when still bound to that exact sample.
    func splitSpeakerEvidence(_ selections: [EnrolledSpeakerEvidence], personID: Int64,
                              newName: String) async throws -> Int64 {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !selections.isEmpty, Set(selections.map(\.id)).count == selections.count else {
            throw StoreError.invalidData("Choose voice samples and a name before splitting")
        }
        let newID = try await db.write { database in
            for selection in selections {
                guard selection.personID == personID,
                      let assignment = try Self.speakerEvidenceAssignment(in: database, sha256: selection.id),
                      assignment.personID == personID, assignment.token == selection.token,
                      let recording = try Recording.fetchOne(database, key: selection.recordingID), recording.deletedAt == nil else {
                    throw StoreError.invalidData("The selected voice samples changed since review")
                }
            }
            let now = Date()
            try database.execute(sql: """
                INSERT INTO people(stable_uuid, display_name, match_threshold, created_at, updated_at, profile_revision)
                VALUES (?, ?, NULL, ?, ?, 1)
                """, arguments: [PersonID.random().description, name, now.timeIntervalSince1970, now.timeIntervalSince1970])
            let newID = database.lastInsertedRowID
            for selection in selections {
                let index = try Int.fetchOne(database, sql: """
                    SELECT speaker_index FROM current_speaker_evidence WHERE recording_id = ? AND evidence_sha256 = ?
                    """, arguments: [selection.recordingID, selection.id])
                if let index, let review = try Self.hostSpeakerReview(in: database,
                    recordingID: selection.recordingID, speakerIndex: index) {
                    try Self.confirmHostSpeakerReview(in: database, review: review, personID: newID)
                } else {
                    _ = try Self.confirmSpeakerEvidence(in: database, sha256: selection.id, personID: newID,
                        expectedToken: selection.token, date: now)
                }
            }
            return newID
        }
        for id in Set(selections.map(\.recordingID)) { await reprojectOKF(id: id) }
        return newID
    }
}
