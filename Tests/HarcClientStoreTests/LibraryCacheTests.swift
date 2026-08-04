import Foundation
import HarcDomain
import Testing
@testable import HarcClientStore

@Suite("HarcLibraryCache path-free persistence")
struct LibraryCacheTests {
    @Test("snapshot, deltas, tombstones, and cursor survive reopen")
    func snapshotDeltaAndReopen() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = RecordingStorageAttributes()
        let libraryID = LibraryID(ClientStoreFixtures.uuid(1))
        let first = ClientStoreFixtures.summary(revision: 1, title: "First")

        do {
            let cache = try HarcLibraryCache(
                rootDirectory: root,
                storageAttributes: attributes
            )
            try cache.replace(
                with: AnchoredLibrarySnapshot(
                    libraryID: libraryID,
                    anchor: ChangeCursor(5),
                    recordings: [first],
                    tombstones: []
                )
            )
            let revised = ClientStoreFixtures.summary(revision: 2, title: "Revised")
            try cache.apply(
                ClientLibraryDelta(
                    libraryID: libraryID,
                    after: ChangeCursor(5),
                    through: ChangeCursor(6),
                    recordings: [revised],
                    tombstones: []
                )
            )
            let tombstone = try RecordingTombstone(
                canonicalID: first.canonicalID,
                revision: EntityRevision(3),
                deletedAt: ClientStoreFixtures.baseDate.addingTimeInterval(20)
            )
            try cache.apply(
                ClientLibraryDelta(
                    libraryID: libraryID,
                    after: ChangeCursor(6),
                    through: ChangeCursor(7),
                    recordings: [],
                    tombstones: [tombstone]
                )
            )
            #expect(try cache.recording(id: first.canonicalID) == nil)
            #expect(try cache.tombstones() == [tombstone])
        }

        let reopened = try HarcLibraryCache(
            rootDirectory: root,
            storageAttributes: attributes
        )
        let state = try #require(try reopened.state())
        #expect(state.libraryID == libraryID)
        #expect(state.changeCursor == ChangeCursor(7))
        #expect(try reopened.recordings().isEmpty)
        #expect(try reopened.tombstones().count == 1)

        #expect(throws: ClientStoreError.self) {
            try reopened.apply(
                ClientLibraryDelta(
                    libraryID: libraryID,
                    after: ChangeCursor(6),
                    through: ChangeCursor(8),
                    recordings: [],
                    tombstones: []
                )
            )
        }
        #expect(try reopened.state()?.changeCursor == ChangeCursor(7))
    }

    @Test("revision rollback and same-revision equivocation are transactional")
    func revisionRules() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try HarcLibraryCache(
            rootDirectory: root,
            storageAttributes: RecordingStorageAttributes()
        )
        let libraryID = LibraryID(ClientStoreFixtures.uuid(1))
        let revisionTwo = ClientStoreFixtures.summary(revision: 2, title: "Current")
        try cache.replace(
            with: AnchoredLibrarySnapshot(
                libraryID: libraryID,
                anchor: ChangeCursor(2),
                recordings: [revisionTwo],
                tombstones: []
            )
        )
        // An exact same-anchor replay is idempotent; changed content at the
        // same cursor is a cache consistency failure.
        try cache.replace(
            with: AnchoredLibrarySnapshot(
                libraryID: libraryID,
                anchor: ChangeCursor(2),
                recordings: [revisionTwo],
                tombstones: []
            )
        )
        #expect(throws: ClientStoreError.self) {
            try cache.replace(
                with: AnchoredLibrarySnapshot(
                    libraryID: libraryID,
                    anchor: ChangeCursor(2),
                    recordings: [ClientStoreFixtures.summary(revision: 2, title: "Changed at same anchor")],
                    tombstones: []
                )
            )
        }

        #expect(throws: ClientStoreError.self) {
            try cache.apply(
                ClientLibraryDelta(
                    libraryID: libraryID,
                    after: ChangeCursor(2),
                    through: ChangeCursor(3),
                    recordings: [ClientStoreFixtures.summary(revision: 1, title: "Old")],
                    tombstones: []
                )
            )
        }
        #expect(try cache.state()?.changeCursor == ChangeCursor(2))
        #expect(try cache.recording(id: revisionTwo.canonicalID)?.title == "Current")

        #expect(throws: ClientStoreError.self) {
            try cache.apply(
                ClientLibraryDelta(
                    libraryID: libraryID,
                    after: ChangeCursor(2),
                    through: ChangeCursor(3),
                    recordings: [ClientStoreFixtures.summary(revision: 2, title: "Equivocation")],
                    tombstones: []
                )
            )
        }
        #expect(try cache.state()?.changeCursor == ChangeCursor(2))
        #expect(try cache.recording(id: revisionTwo.canonicalID)?.title == "Current")
    }

    @Test("offline mutations and visible conflicts are path-free and durable")
    func mutationsAndConflicts() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = RecordingStorageAttributes()
        let libraryID = LibraryID(ClientStoreFixtures.uuid(1))
        let summary = ClientStoreFixtures.summary(revision: 2)
        let operationID = OperationID(ClientStoreFixtures.uuid(600))

        do {
            let cache = try HarcLibraryCache(
                rootDirectory: root,
                storageAttributes: attributes
            )
            try cache.replace(
                with: AnchoredLibrarySnapshot(
                    libraryID: libraryID,
                    anchor: ChangeCursor(2),
                    recordings: [summary],
                    tombstones: []
                )
            )
            let mutation = try OfflineMetadataMutation(
                operationID: operationID,
                libraryID: libraryID,
                canonicalRecordingID: summary.canonicalID,
                expectedRevision: summary.revision,
                kind: .setTitle,
                exactPayload: Data("New title".utf8),
                createdAt: ClientStoreFixtures.baseDate
            )
            try cache.persistOfflineMutation(mutation)
            try cache.persistOfflineMutation(mutation)
            let conflict = try VisibleLibraryConflict(
                operationID: operationID,
                libraryID: libraryID,
                canonicalRecordingID: summary.canonicalID,
                expectedRevision: summary.revision,
                currentRevision: summary.revision,
                currentValue: summary,
                createdAt: ClientStoreFixtures.baseDate.addingTimeInterval(1)
            )
            try cache.recordConflict(conflict)
            #expect(try cache.offlineMutations().first?.state == .conflicted)
            #expect(try cache.conflicts() == [conflict])
            try cache.resolveConflict(conflict.conflictID)
            try cache.updateOfflineMutationState(
                operationID: operationID,
                state: .completed
            )
            #expect(try cache.conflicts().isEmpty)
            #expect(try cache.offlineMutations().isEmpty)
        }

        let reopened = try HarcLibraryCache(
            rootDirectory: root,
            storageAttributes: attributes
        )
        #expect(try reopened.offlineMutations().isEmpty)
        #expect(try reopened.conflicts().isEmpty)
        #expect(try reopened.conflicts(includeResolved: true).count == 1)
    }

    @Test("a new library snapshot replaces only protected cache content")
    func newLibraryReplacement() throws {
        let root = temporaryClientStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try HarcLibraryCache(
            rootDirectory: root,
            storageAttributes: RecordingStorageAttributes()
        )
        let firstLibrary = LibraryID(ClientStoreFixtures.uuid(1))
        let secondLibrary = LibraryID(ClientStoreFixtures.uuid(2))
        try cache.replace(
            with: AnchoredLibrarySnapshot(
                libraryID: firstLibrary,
                anchor: ChangeCursor(10),
                recordings: [ClientStoreFixtures.summary(id: 1)],
                tombstones: []
            )
        )
        try cache.replace(
            with: AnchoredLibrarySnapshot(
                libraryID: secondLibrary,
                anchor: ChangeCursor(1),
                recordings: [ClientStoreFixtures.summary(id: 2)],
                tombstones: []
            )
        )
        #expect(try cache.state()?.libraryID == secondLibrary)
        #expect(try cache.state()?.changeCursor == ChangeCursor(1))
        #expect(try cache.recordings().map(\.canonicalID) == [CanonicalRecordingID(ClientStoreFixtures.uuid(2))])
    }
}
