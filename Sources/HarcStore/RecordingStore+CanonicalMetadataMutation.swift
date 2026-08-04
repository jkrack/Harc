import Foundation
import GRDB
import HarcDomain

public enum CanonicalMetadataMutation: Codable, Equatable, Sendable {
    case setTitle(String?)
    case replaceTags([String])
    case setSpeakerLabel(index: UInt32, displayName: String?)
    case setNotesMarkdown(String?)
    case setPinned(Bool)
}

public enum CanonicalMetadataFieldValue: Codable, Equatable, Sendable {
    case title(String?)
    case tags([String])
    case speakerLabel(index: UInt32, displayName: String?)
    case notesMarkdown(String?)
    case pinned(Bool)
}

public enum CanonicalMetadataMutationResult: Codable, Equatable, Sendable {
    case applied(newRevision: EntityRevision, changeCursor: ChangeCursor)
    case conflict(currentRevision: EntityRevision, currentValue: CanonicalMetadataFieldValue)
}

public extension RecordingStore {
    /// Applies one signed metadata operation exactly once. The operation
    /// record, visible row mutation, revision bump, and change-log append are
    /// one SQLite transaction so Host.db recovery can safely reconcile by the
    /// same operation ID after a process or machine failure.
    func applyCanonicalMetadataMutation(
        operationID: OperationID,
        exactRequestSHA256: Data,
        canonicalID: CanonicalRecordingID,
        expectedRevision: EntityRevision,
        mutation: CanonicalMetadataMutation,
        at date: Date
    ) async throws -> CanonicalMetadataMutationResult {
        guard exactRequestSHA256.count == 32 else {
            throw StoreError.invalidData("Metadata mutation request digest must be 32 bytes")
        }
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw StoreError.invalidData("Metadata mutation date is invalid")
        }
        try Self.validateCanonicalMetadataMutation(mutation)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let result = try await db.write { database in
            if let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT exact_request_sha256, result_json
                    FROM canonical_metadata_operations
                    WHERE operation_id = ?
                    """,
                arguments: [operationID.description]
            ) {
                guard row["exact_request_sha256"] as Data == exactRequestSHA256 else {
                    throw StoreError.invalidData("Metadata mutation operation identity was reused")
                }
                do {
                    return try decoder.decode(
                        CanonicalMetadataMutationResult.self,
                        from: row["result_json"] as Data
                    )
                } catch {
                    throw StoreError.invalidData("Stored metadata mutation result is corrupt")
                }
            }

            guard let recording = try Recording
                .filter(Recording.Columns.canonicalID == canonicalID.description)
                .fetchOne(database), recording.deletedAt == nil,
                let recordingID = recording.id else {
                throw StoreError.notFound
            }

            let result: CanonicalMetadataMutationResult
            if recording.revision != expectedRevision {
                result = .conflict(
                    currentRevision: recording.revision,
                    currentValue: Self.currentMetadataFieldValue(
                        recording: recording,
                        mutation: mutation
                    )
                )
            } else {
                let values = try Self.metadataMutationAssignments(
                    recording: recording,
                    mutation: mutation,
                    updatedAt: date
                )
                let expectedRevisionValue = try expectedRevision.signedInt64Value()
                let count = try Recording
                    .filter(key: recordingID)
                    .filter(Recording.Columns.revision == expectedRevisionValue)
                    .updateAll(database, values)
                guard count == 1 else {
                    throw StoreError.revisionConflict(
                        expected: expectedRevision.rawValue,
                        actual: recording.revision.rawValue
                    )
                }
                let cursorValue = try Self.bumpRevisionAndAppendLibraryChange(
                    in: database,
                    recordingID: recordingID,
                    changedAt: date
                )
                guard let newRevisionValue = try Int64.fetchOne(
                    database,
                    sql: "SELECT revision FROM recordings WHERE id = ?",
                    arguments: [recordingID]
                ) else { throw StoreError.notFound }
                result = .applied(
                    newRevision: try EntityRevision(signedValue: newRevisionValue),
                    changeCursor: try ChangeCursor(signedValue: cursorValue)
                )
            }

            let resultJSON = try encoder.encode(result)
            try database.execute(
                sql: """
                    INSERT INTO canonical_metadata_operations
                        (operation_id, exact_request_sha256, result_json, recorded_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    operationID.description,
                    exactRequestSHA256,
                    resultJSON,
                    date,
                ]
            )
            return result
        }
        if case .applied = result,
           let recording = try await fetch(canonicalID: canonicalID),
           let recordingID = recording.id {
            await reprojectOKF(id: recordingID)
        }
        return result
    }

    private static func validateCanonicalMetadataMutation(
        _ mutation: CanonicalMetadataMutation
    ) throws {
        func validateOptional(_ value: String?, field: String) throws {
            guard let value else { return }
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= 1_048_576 else {
                throw StoreError.invalidData("Invalid \(field)")
            }
        }
        switch mutation {
        case .setTitle(let value):
            try validateOptional(value, field: "title")
        case .replaceTags(let values):
            guard values == values.sorted(), Set(values).count == values.count else {
                throw StoreError.invalidData("Tags must be sorted and duplicate-free")
            }
            for value in values { try validateOptional(value, field: "tag") }
        case .setSpeakerLabel(_, let value):
            try validateOptional(value, field: "speaker label")
        case .setNotesMarkdown(let value):
            try validateOptional(value, field: "notes")
        case .setPinned:
            break
        }
    }

    private static func currentMetadataFieldValue(
        recording: Recording,
        mutation: CanonicalMetadataMutation
    ) -> CanonicalMetadataFieldValue {
        switch mutation {
        case .setTitle:
            return .title(recording.title)
        case .replaceTags:
            return .tags(recording.tags)
        case .setSpeakerLabel(let index, _):
            return .speakerLabel(
                index: index,
                displayName: Int(exactly: index).flatMap { recording.speakerNames[$0] }
            )
        case .setNotesMarkdown:
            return .notesMarkdown(recording.notesMarkdown)
        case .setPinned:
            return .pinned(recording.pinned)
        }
    }

    private static func metadataMutationAssignments(
        recording: Recording,
        mutation: CanonicalMetadataMutation,
        updatedAt: Date
    ) throws -> [ColumnAssignment] {
        var assignments: [ColumnAssignment] = [
            Recording.Columns.updatedAt.set(to: updatedAt)
        ]
        switch mutation {
        case .setTitle(let value):
            assignments.append(Recording.Columns.title.set(to: value))
        case .replaceTags(let values):
            let json = values.isEmpty
                ? nil
                : String(data: try JSONEncoder().encode(values), encoding: .utf8)
            assignments.append(Recording.Columns.tags.set(to: json))
        case .setSpeakerLabel(let index, let displayName):
            guard let integerIndex = Int(exactly: index) else {
                throw StoreError.invalidData("Speaker index is out of range")
            }
            var names = recording.speakerNames
            names[integerIndex] = displayName
            let json: String?
            if names.isEmpty {
                json = nil
            } else {
                let encoded = Dictionary(uniqueKeysWithValues: names.map {
                    (String($0.key), $0.value)
                })
                json = String(data: try JSONEncoder().encode(encoded), encoding: .utf8)
            }
            assignments.append(Recording.Columns.speakerNames.set(to: json))
        case .setNotesMarkdown(let value):
            assignments.append(Recording.Columns.notesMarkdown.set(to: value))
        case .setPinned(let value):
            assignments.append(Recording.Columns.pinned.set(to: value))
        }
        return assignments
    }
}
