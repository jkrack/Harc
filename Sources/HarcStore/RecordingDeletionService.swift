import Foundation
import HarcCore

public protocol RecordingFileTrashing: Sendable {
    func trashFile(at url: URL) throws
}

public struct SystemRecordingFileTrasher: RecordingFileTrashing {
    public init() {}

    public func trashFile(at url: URL) throws {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    }
}

public enum RecordingDeletionError: Error, LocalizedError, Sendable {
    case missingRecordingID
    case fileTrashFailed(path: String, underlyingDescription: String, restoredLibraryEntry: Bool)

    public var errorDescription: String? {
        switch self {
        case .missingRecordingID:
            return "The recording is missing a database id."
        case .fileTrashFailed(let path, let underlyingDescription, let restoredLibraryEntry):
            let restored = restoredLibraryEntry
                ? "The Library entry was restored so you can retry."
                : "Harc could not restore the Library entry automatically."
            return """
            Harc could not move one of the recording files to Trash.

            File:
            \(path)

            \(underlyingDescription)

            \(restored)
            """
        }
    }
}

public struct RecordingDeletionService<Trasher: RecordingFileTrashing>: Sendable {
    private let store: RecordingStore
    private let trasher: Trasher
    private let fileExists: @Sendable (String) -> Bool

    public init(
        store: RecordingStore,
        trasher: Trasher,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.store = store
        self.trasher = trasher
        self.fileExists = fileExists
    }

    public func delete(recording: Recording) async throws {
        guard let id = recording.id else { throw RecordingDeletionError.missingRecordingID }

        try await store.softDelete(id: id)

        do {
            try trashExistingFiles(for: recording)
        } catch let error as RecordingDeletionError {
            let restored = await restoreIfPossible(id: id)
            if case .fileTrashFailed(let path, let description, _) = error {
                throw RecordingDeletionError.fileTrashFailed(
                    path: path,
                    underlyingDescription: description,
                    restoredLibraryEntry: restored
                )
            }
            throw error
        } catch {
            let restored = await restoreIfPossible(id: id)
            throw RecordingDeletionError.fileTrashFailed(
                path: recording.wavPath,
                underlyingDescription: error.localizedDescription,
                restoredLibraryEntry: restored
            )
        }
    }

    private func trashExistingFiles(for recording: Recording) throws {
        for path in recording.deletionFilePaths {
            guard fileExists(path) else { continue }
            do {
                try trasher.trashFile(at: URL(fileURLWithPath: path))
            } catch {
                throw RecordingDeletionError.fileTrashFailed(
                    path: path,
                    underlyingDescription: error.localizedDescription,
                    restoredLibraryEntry: false
                )
            }
        }
        OKFMarkdown.regenerateDayIndex(
            in: URL(fileURLWithPath: recording.wavPath).deletingLastPathComponent()
        )
    }

    private func restoreIfPossible(id: Int64) async -> Bool {
        do {
            try await store.restore(id: id)
            return true
        } catch {
            return false
        }
    }
}

public extension RecordingDeletionService where Trasher == SystemRecordingFileTrasher {
    init(store: RecordingStore) {
        self.init(store: store, trasher: SystemRecordingFileTrasher())
    }
}

private extension Recording {
    var deletionFilePaths: [String] {
        // Legacy rows may point txtPath at a `.txt` while a generated OKF
        // `.md` also exists next to the WAV — include the derived path so
        // neither is orphaned.
        let mdPath = OKFProjection.markdownURL(for: self).path
        var seen = Set<String>()
        return [wavPath, txtPath, mdPath, jsonPath]
            .compactMap { $0 }
            .filter { seen.insert($0).inserted }
    }
}
