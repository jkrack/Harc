import Testing
import Foundation
@testable import HarcStore

@Suite("RecordingDeletionService")
struct RecordingDeletionServiceTests {
    private final class TrashRecorder: RecordingFileTrashing, @unchecked Sendable {
        var trashedPaths: [String] = []
        var failingPath: String?

        func trashFile(at url: URL) throws {
            let path = url.path
            if path == failingPath {
                throw NSError(
                    domain: "RecordingDeletionServiceTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "trash failed"]
                )
            }
            trashedPaths.append(path)
        }
    }

    private func sampleRecording(root: URL) -> Recording {
        let wav = root.appendingPathComponent("meeting.wav").path
        return Recording(
            wavPath: wav,
            txtPath: root.appendingPathComponent("meeting.txt").path,
            jsonPath: root.appendingPathComponent("meeting.json").path,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060),
            transcriptText: "hello"
        )
    }

    @Test("delete soft-deletes the row and trashes existing recording files")
    func deleteSoftDeletesAndTrashesFiles() async throws {
        let store = try await RecordingStore.inMemory()
        let root = URL(fileURLWithPath: "/tmp/harc-delete-success", isDirectory: true)
        let saved = try await store.upsert(sampleRecording(root: root))
        let trasher = TrashRecorder()
        let existing = Set([saved.wavPath, saved.txtPath, saved.jsonPath].compactMap { $0 })

        let service = RecordingDeletionService(
            store: store,
            trasher: trasher,
            fileExists: { existing.contains($0) }
        )

        try await service.delete(recording: saved)

        #expect(try await store.fetchAll() == [])
        #expect(try await store.fetchAll(includeDeleted: true).first?.deletedAt != nil)
        #expect(trasher.trashedPaths == [saved.wavPath, saved.txtPath, saved.jsonPath])
    }

    @Test("delete restores the row and reports failure when trashing a file fails")
    func trashFailureRestoresLibraryRow() async throws {
        let store = try await RecordingStore.inMemory()
        let root = URL(fileURLWithPath: "/tmp/harc-delete-trash-failure", isDirectory: true)
        let saved = try await store.upsert(sampleRecording(root: root))
        let trasher = TrashRecorder()
        trasher.failingPath = saved.txtPath
        let existing = Set([saved.wavPath, saved.txtPath, saved.jsonPath].compactMap { $0 })

        let service = RecordingDeletionService(
            store: store,
            trasher: trasher,
            fileExists: { existing.contains($0) }
        )

        do {
            try await service.delete(recording: saved)
            Issue.record("Expected delete to fail")
        } catch RecordingDeletionError.fileTrashFailed(let path, _, let restored) {
            #expect(path == saved.txtPath)
            #expect(restored == true)
        }

        let visible = try await store.fetchAll()
        #expect(visible.count == 1)
        #expect(visible.first?.deletedAt == nil)
        #expect(trasher.trashedPaths == [saved.wavPath])
    }

    @Test("delete does not trash files when the database update fails")
    func databaseFailureDoesNotTrashFiles() async throws {
        let store = try await RecordingStore.inMemory()
        let root = URL(fileURLWithPath: "/tmp/harc-delete-db-failure", isDirectory: true)
        var missing = sampleRecording(root: root)
        missing.id = 999
        let trasher = TrashRecorder()

        let service = RecordingDeletionService(
            store: store,
            trasher: trasher,
            fileExists: { _ in true }
        )

        await #expect(throws: Error.self) {
            try await service.delete(recording: missing)
        }
        #expect(trasher.trashedPaths.isEmpty)
    }
}
