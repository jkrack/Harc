import Foundation
import GRDB
import HarcDomain
import Testing
@testable import HarcStore

@Suite("Canonical library integration")
struct CanonicalLibraryIntegrationTests {
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func recording(
        path: String,
        title: String = "Quarterly planning",
        deletedAt: Date? = nil
    ) -> Recording {
        Recording(
            wavPath: path,
            txtPath: path.replacingOccurrences(of: ".wav", with: ".md"),
            jsonPath: path.replacingOccurrences(of: ".wav", with: ".json"),
            startedAt: baseDate,
            endedAt: baseDate.addingTimeInterval(90),
            title: title,
            transcriptText: "Amy and Jason reviewed the quarterly plan.",
            suggestedTitle: "Quarterly review",
            tags: ["planning", "quarterly"],
            speakerNames: [0: "Amy", 1: "Jason"],
            pinned: true,
            deletedAt: deletedAt,
            summaryMarkdown: "The plan remains on schedule.",
            actionItemsMarkdown: "- [ ] Jason: circulate the plan",
            notesMarkdown: "Keep the launch date visible."
        )
    }

    private func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try #require(String(data: encoder.encode(value), encoding: .utf8))
    }

    @Test("legacy path upsert preserves identity and emits ordered lifecycle changes")
    func legacyPathLifecycle() async throws {
        let store = try await RecordingStore.inMemory()
        let privatePath = "/private/tmp/PATH_SHOULD_NEVER_ESCAPE/legacy.wav"

        let initialMetadata = try await store.libraryMetadata()
        #expect(initialMetadata.writerMode == .standalone)
        #expect(initialMetadata.hostAuthorityID == nil)
        #expect(initialMetadata.hostStateID == nil)
        #expect(initialMetadata.currentChangeCursor == .zero)

        let inserted = try await store.upsert(recording(path: privatePath))
        let rowID = try #require(inserted.id)
        #expect(inserted.revision == .initial)

        let fetchedByCanonicalID = try #require(
            try await store.fetch(canonicalID: inserted.canonicalID)
        )
        #expect(fetchedByCanonicalID.id == rowID)
        #expect(fetchedByCanonicalID.wavPath == privatePath)

        var attemptedReplacement = recording(path: privatePath, title: "Updated locally")
        let untrustedCanonicalID = CanonicalRecordingID.random()
        let untrustedOrigin = OriginRecordingID(
            deviceID: try DeviceID(Data(repeating: 0x41, count: 32)),
            recordingUUID: UUID()
        )
        attemptedReplacement.canonicalID = untrustedCanonicalID
        attemptedReplacement.originID = untrustedOrigin
        attemptedReplacement.canonicalPCMHash = try CanonicalPCMHash(
            Data(repeating: 0x42, count: 32)
        )
        attemptedReplacement.canonicalPCMFrames = 999
        attemptedReplacement.revision = try EntityRevision(99)
        attemptedReplacement.processing = .pending
        attemptedReplacement.projection = .unknownLegacy

        let updated = try await store.upsert(attemptedReplacement)
        #expect(updated.id == rowID)
        #expect(updated.canonicalID == inserted.canonicalID)
        #expect(updated.canonicalID != untrustedCanonicalID)
        #expect(updated.originID == nil)
        #expect(updated.canonicalPCMHash == nil)
        #expect(updated.canonicalPCMFrames == nil)
        #expect(updated.processing == .ready)
        #expect(updated.projection == .readyV1)
        #expect(updated.revision.rawValue == 2)
        #expect(updated.title == "Updated locally")

        try await store.softDelete(id: rowID)
        let deleted = try #require(try await store.fetch(id: rowID))
        #expect(deleted.revision.rawValue == 3)
        #expect(deleted.deletedAt != nil)

        let deletedSnapshot = try await store.anchoredLibrarySnapshot()
        #expect(deletedSnapshot.recordings.isEmpty)
        #expect(deletedSnapshot.tombstones.map(\.canonicalID) == [inserted.canonicalID])
        #expect(deletedSnapshot.tombstones.first?.revision.rawValue == 3)

        let cursorAfterDelete = try await store.libraryMetadata().currentChangeCursor
        try await store.softDelete(id: rowID)
        #expect(try await store.libraryMetadata().currentChangeCursor == cursorAfterDelete)

        try await store.restore(id: rowID)
        let restored = try #require(try await store.fetch(id: rowID))
        #expect(restored.canonicalID == inserted.canonicalID)
        #expect(restored.revision.rawValue == 4)
        #expect(restored.deletedAt == nil)

        let cursorAfterRestore = try await store.libraryMetadata().currentChangeCursor
        try await store.restore(id: rowID)
        #expect(try await store.libraryMetadata().currentChangeCursor == cursorAfterRestore)

        let changes = try await store.libraryChanges(after: .zero)
        #expect(changes.map(\.canonicalID) == Array(repeating: inserted.canonicalID, count: 4))
        #expect(changes.map { $0.revision.rawValue } == [1, 2, 3, 4])
        #expect(changes.map(\.operation) == [.upsert, .upsert, .tombstone, .upsert])
        #expect(changes.map(\.cursor) == changes.map(\.cursor).sorted())
        #expect(Set(changes.map(\.cursor)).count == changes.count)
        #expect(try await store.libraryMetadata().currentChangeCursor == changes.last?.cursor)

        let restoredSnapshot = try await store.anchoredLibrarySnapshot()
        #expect(restoredSnapshot.anchor == changes.last?.cursor)
        #expect(restoredSnapshot.recordings.map(\.canonicalID) == [inserted.canonicalID])
        #expect(restoredSnapshot.tombstones.isEmpty)

        let detail = try #require(
            try await store.recordingDetail(canonicalID: inserted.canonicalID)
        )
        #expect(detail.summary.revision.rawValue == 4)
        #expect(detail.transcriptText == "Amy and Jason reviewed the quarterly plan.")
        #expect(detail.speakerLabels.map(\.displayName) == ["Amy", "Jason"])

        let encodedSnapshot = try jsonString(restoredSnapshot)
        let encodedDetail = try jsonString(detail)
        for encoded in [encodedSnapshot, encodedDetail] {
            #expect(!encoded.contains("PATH_SHOULD_NEVER_ESCAPE"))
            #expect(!encoded.contains("wavPath"))
            #expect(!encoded.contains("txtPath"))
            #expect(!encoded.contains("jsonPath"))
        }
    }

    @Test("origin ingest is idempotent and rejects conflicting audio bindings")
    func originIngestIdempotencyAndConflicts() async throws {
        let store = try await RecordingStore.inMemory()
        let origin = OriginRecordingID(
            deviceID: try DeviceID(Data(repeating: 0x11, count: 32)),
            recordingUUID: UUID()
        )
        let hash = try CanonicalPCMHash(Data(repeating: 0x22, count: 32))
        let otherHash = try CanonicalPCMHash(Data(repeating: 0x23, count: 32))

        var clientSuppliedRecording = recording(
            path: "/private/tmp/PATH_SHOULD_NEVER_ESCAPE/origin.wav"
        )
        let clientSuppliedCanonicalID = CanonicalRecordingID.random()
        clientSuppliedRecording.canonicalID = clientSuppliedCanonicalID
        clientSuppliedRecording.processing = .ready
        clientSuppliedRecording.projection = .readyV1
        clientSuppliedRecording.deletedAt = baseDate
        let inserted = try await store.insertFromOrigin(
            clientSuppliedRecording,
            originID: origin,
            canonicalPCMHash: hash,
            canonicalPCMFrames: 32_000
        )
        #expect(inserted.canonicalID != clientSuppliedCanonicalID)
        #expect(inserted.originID == origin)
        #expect(inserted.canonicalPCMHash == hash)
        #expect(inserted.canonicalPCMFrames == 32_000)
        #expect(inserted.revision == .initial)
        #expect(inserted.processing == .pending)
        #expect(inserted.projection == .pending)
        #expect(inserted.deletedAt == nil)

        let cursorAfterInsert = try await store.libraryMetadata().currentChangeCursor
        let replay = try await store.insertFromOrigin(
            recording(
                path: "/private/tmp/PATH_SHOULD_NEVER_ESCAPE/replayed-at-another-path.wav",
                title: "Replay must not replace metadata"
            ),
            originID: origin,
            canonicalPCMHash: hash,
            canonicalPCMFrames: 32_000
        )
        #expect(replay.id == inserted.id)
        #expect(replay.canonicalID == inserted.canonicalID)
        #expect(replay.wavPath == inserted.wavPath)
        #expect(replay.title == inserted.title)
        #expect(replay.revision == .initial)
        #expect(try await store.libraryMetadata().currentChangeCursor == cursorAfterInsert)
        #expect(try await store.libraryChanges(after: .zero).count == 1)

        do {
            _ = try await store.insertFromOrigin(
                recording(path: "/tmp/conflicting-hash.wav"),
                originID: origin,
                canonicalPCMHash: otherHash,
                canonicalPCMFrames: 32_000
            )
            Issue.record("Expected a conflicting origin/hash binding to fail")
        } catch let error as StoreError {
            #expect(error == .originIdentityConflict)
        }

        do {
            _ = try await store.insertFromOrigin(
                recording(path: "/tmp/conflicting-frames.wav"),
                originID: origin,
                canonicalPCMHash: hash,
                canonicalPCMFrames: 31_999
            )
            Issue.record("Expected a conflicting origin/frame binding to fail")
        } catch let error as StoreError {
            #expect(error == .originIdentityConflict)
        }

        #expect(try await store.libraryMetadata().currentChangeCursor == cursorAfterInsert)
        #expect(try await store.libraryChanges(after: .zero).count == 1)

        let detail = try #require(
            try await store.recordingDetail(canonicalID: inserted.canonicalID)
        )
        #expect(detail.summary.originID == origin)
        #expect(detail.summary.canonicalAudio.availability == .available)
        #expect(detail.summary.canonicalAudio.pcmSHA256 == hash)
        #expect(detail.summary.canonicalAudio.totalFrames == 32_000)
        #expect(detail.summary.canonicalAudio.format == .harcV1)
        let encodedDetail = try jsonString(detail)
        #expect(!encodedDetail.contains("PATH_SHOULD_NEVER_ESCAPE"))
    }

    @Test("canonical audio, processing, and projection mutations share revision order")
    func canonicalStateMutationOrdering() async throws {
        let store = try await RecordingStore.inMemory()
        let inserted = try await store.upsert(recording(path: "/tmp/state.wav"))
        let rowID = try #require(inserted.id)
        let hash = try CanonicalPCMHash(Data(repeating: 0x31, count: 32))

        try await store.setCanonicalPCM(id: rowID, hash: hash, totalFrames: 48_000)
        let afterPCM = try #require(try await store.fetch(id: rowID))
        #expect(afterPCM.revision.rawValue == 2)
        #expect(afterPCM.canonicalPCMHash == hash)
        #expect(afterPCM.canonicalPCMFrames == 48_000)

        let cursorAfterPCM = try await store.libraryMetadata().currentChangeCursor
        try await store.setCanonicalPCM(id: rowID, hash: hash, totalFrames: 48_000)
        #expect(try await store.libraryMetadata().currentChangeCursor == cursorAfterPCM)

        let otherHash = try CanonicalPCMHash(Data(repeating: 0x32, count: 32))
        do {
            try await store.setCanonicalPCM(id: rowID, hash: otherHash, totalFrames: 48_000)
            Issue.record("Expected canonical PCM to be write-once")
        } catch let error as StoreError {
            #expect(error == .canonicalPCMHashConflict)
        }

        let processing = try ProcessingDescriptor(
            state: .degraded,
            failure: ProcessingFailure(code: "stt.partial", message: "One range needs retry")
        )
        try await store.updateProcessing(id: rowID, descriptor: processing)
        let afterProcessing = try #require(try await store.fetch(id: rowID))
        #expect(afterProcessing.revision.rawValue == 3)
        #expect(afterProcessing.processing == processing)

        let cursorAfterProcessing = try await store.libraryMetadata().currentChangeCursor
        try await store.updateProcessing(id: rowID, descriptor: processing)
        #expect(try await store.libraryMetadata().currentChangeCursor == cursorAfterProcessing)

        let projection = try ProjectionDescriptor(
            state: .degraded,
            version: ProjectionVersion(2),
            failure: ProcessingFailure(
                code: "projection.okf_retry",
                message: "OKF projection will be retried"
            )
        )
        try await store.updateProjection(id: rowID, descriptor: projection)
        let afterProjection = try #require(try await store.fetch(id: rowID))
        #expect(afterProjection.revision.rawValue == 4)
        #expect(afterProjection.projection == projection)

        let cursorAfterProjection = try await store.libraryMetadata().currentChangeCursor
        try await store.updateProjection(id: rowID, descriptor: projection)
        #expect(try await store.libraryMetadata().currentChangeCursor == cursorAfterProjection)

        let changes = try await store.libraryChanges(after: .zero)
        #expect(changes.map { $0.revision.rawValue } == [1, 2, 3, 4])
        #expect(changes.map(\.operation) == Array(repeating: .upsert, count: 4))
        #expect(changes.map(\.cursor) == changes.map(\.cursor).sorted())
        #expect(try await store.libraryMetadata().currentChangeCursor == changes.last?.cursor)

        let detail = try #require(
            try await store.recordingDetail(canonicalID: inserted.canonicalID)
        )
        #expect(detail.summary.revision.rawValue == 4)
        #expect(detail.summary.canonicalAudio.pcmSHA256 == hash)
        #expect(detail.summary.canonicalAudio.totalFrames == 48_000)
        #expect(detail.summary.processing == processing)
        #expect(detail.summary.projection == projection)

        try await store.softDelete(id: rowID)
        let deletedProcessing = try ProcessingDescriptor(
            state: .failedRecoverable,
            failure: ProcessingFailure(code: "stt.retry")
        )
        try await store.updateProcessing(id: rowID, descriptor: deletedProcessing)
        let postDeleteChanges = try await store.libraryChanges(after: .zero)
        #expect(postDeleteChanges.suffix(2).map(\.operation) == [.tombstone, .tombstone])
    }

    @Test("a populated v15 library snapshots all rows while its migrated log is empty")
    func migratedV15AnchoredSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-canonical-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("Harc.db")

        let activePath = root.appendingPathComponent("PATH_SHOULD_NEVER_ESCAPE-active.wav").path
        let deletedPath = root.appendingPathComponent("PATH_SHOULD_NEVER_ESCAPE-deleted.wav").path
        let deletedAt = baseDate.addingTimeInterval(120)

        do {
            let legacyDatabase = try DatabaseQueue(path: databaseURL.path)
            try DatabaseMigrator.harcMigrator().migrate(
                legacyDatabase,
                upTo: "v15_notes"
            )
            try await legacyDatabase.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO recordings
                            (wav_path, txt_path, json_path, started_at, ended_at,
                             title, transcript_text, pinned, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                        """,
                    arguments: [
                        activePath,
                        root.appendingPathComponent("PATH_SHOULD_NEVER_ESCAPE-active.md").path,
                        root.appendingPathComponent("PATH_SHOULD_NEVER_ESCAPE-active.json").path,
                        baseDate,
                        baseDate.addingTimeInterval(90),
                        "Legacy active",
                        "Legacy active transcript",
                        baseDate,
                        baseDate,
                    ]
                )
                try database.execute(
                    sql: """
                        INSERT INTO recordings
                            (wav_path, txt_path, json_path, started_at, ended_at,
                             title, transcript_text, pinned, deleted_at,
                             created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
                        """,
                    arguments: [
                        deletedPath,
                        root.appendingPathComponent("PATH_SHOULD_NEVER_ESCAPE-deleted.md").path,
                        root.appendingPathComponent("PATH_SHOULD_NEVER_ESCAPE-deleted.json").path,
                        baseDate.addingTimeInterval(30),
                        baseDate.addingTimeInterval(60),
                        "Legacy deleted",
                        "Legacy deleted transcript",
                        deletedAt,
                        baseDate,
                        baseDate,
                    ]
                )
            }
        }

        let store = try await RecordingStore.onDisk(url: databaseURL)
        let metadata = try await store.libraryMetadata()
        #expect(metadata.writerMode == .standalone)
        #expect(metadata.currentChangeCursor == .zero)
        #expect(try await store.libraryChanges(after: .zero).isEmpty)

        let snapshot = try await store.anchoredLibrarySnapshot()
        #expect(snapshot.libraryID == metadata.libraryID)
        #expect(snapshot.anchor == .zero)
        #expect(snapshot.recordings.count == 1)
        #expect(snapshot.tombstones.count == 1)
        #expect(snapshot.recordings.first?.title == "Legacy active")
        #expect(snapshot.recordings.first?.revision == .initial)
        #expect(snapshot.recordings.first?.canonicalAudio == .unavailablePendingHash)
        #expect(snapshot.recordings.first?.processing == .ready)
        #expect(snapshot.recordings.first?.projection == .unknownLegacy)
        #expect(snapshot.tombstones.first?.revision == .initial)
        #expect(snapshot.tombstones.first?.deletedAt == deletedAt)

        let canonicalID = try #require(snapshot.recordings.first?.canonicalID)
        let internalRow = try #require(try await store.fetch(canonicalID: canonicalID))
        #expect(internalRow.wavPath == activePath)
        #expect(internalRow.canonicalID == canonicalID)

        let detail = try #require(try await store.recordingDetail(canonicalID: canonicalID))
        #expect(detail.transcriptText == "Legacy active transcript")
        #expect(detail.summary.projection == .unknownLegacy)

        let encodedSnapshot = try jsonString(snapshot)
        let encodedDetail = try jsonString(detail)
        for encoded in [encodedSnapshot, encodedDetail] {
            #expect(!encoded.contains("PATH_SHOULD_NEVER_ESCAPE"))
            #expect(!encoded.contains(root.path))
            #expect(!encoded.contains("wavPath"))
            #expect(!encoded.contains("txtPath"))
            #expect(!encoded.contains("jsonPath"))
        }

        let reopened = try await RecordingStore.onDisk(url: databaseURL)
        #expect(try await reopened.libraryMetadata().libraryID == metadata.libraryID)
        let reopenedSnapshot = try await reopened.anchoredLibrarySnapshot()
        #expect(reopenedSnapshot.recordings.map(\.canonicalID) == snapshot.recordings.map(\.canonicalID))
        #expect(reopenedSnapshot.tombstones.map(\.canonicalID) == snapshot.tombstones.map(\.canonicalID))
        #expect(try await reopened.libraryChanges(after: .zero).isEmpty)
    }
}
