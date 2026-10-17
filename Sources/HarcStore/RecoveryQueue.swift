import Foundation
import HarcCore

public struct RecoveryArtifact: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case interruptedWAV
        case finalizedMissingDatabaseRow
        case timeoutFinalizing
        case destinationMoveFailed
        case noteLinkFailed
    }

    public enum Status: String, Codable, Sendable {
        case pending
        case recovering
        case recovered
        case skipped
        case discarded
        case failed
    }

    public var id: String
    public var kind: Kind
    public var status: Status
    public var sourceURL: URL
    public var destinationURL: URL?
    /// Reserved before publication; survives a crash between file/DB commit
    /// and the queue's completion write. Absent in legacy queue records.
    public var recoveryOutputURL: URL?
    public var recordingID: Int64?
    public var title: String
    public var detail: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastError: String?

    public init(
        id: String,
        kind: Kind,
        status: Status = .pending,
        sourceURL: URL,
        destinationURL: URL? = nil,
        recoveryOutputURL: URL? = nil,
        recordingID: Int64? = nil,
        title: String,
        detail: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastError: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.recoveryOutputURL = recoveryOutputURL
        self.recordingID = recordingID
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastError = lastError
    }
}

public actor RecoveryQueue {
    public enum QueueError: Error, LocalizedError, Sendable {
        case artifactNotFound(String)
        case missingDestination(String)
        case artifactBusy(String)
        case sourceIdentityChanged(String)

        public var errorDescription: String? {
            switch self {
            case .artifactNotFound(let id):
                return "Recovery artifact \(id) was not found."
            case .missingDestination(let id):
                return "Recovery artifact \(id) does not have a destination directory."
            case .artifactBusy(let id):
                return "Recovery artifact \(id) is already being recovered."
            case .sourceIdentityChanged(let id):
                return "Recovery artifact \(id) cannot be rebound to a different source file."
            }
        }
    }

    public let fileURL: URL
    private let store: RecordingStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var artifacts: [RecoveryArtifact] = []
    private var loaded = false
    private var recoveringSources: Set<String> = []
    private let writeMetadata: @Sendable (Data, URL) throws -> Void
    private let publish: @Sendable (RecordingCacheRecovery, URL, URL) async throws -> Recording

    public init(fileURL: URL, store: RecordingStore) {
        self.init(fileURL: fileURL, store: store, writeMetadata: { data, url in
            try DurableFileIO.writeAtomically(data, to: url)
        })
    }

    /// I/O seams let failure tests interrupt real publication at its commit
    /// boundary without timing sleeps or touching the user's recordings.
    init(
        fileURL: URL,
        store: RecordingStore,
        writeMetadata: @escaping @Sendable (Data, URL) throws -> Void,
        publish: @escaping @Sendable (RecordingCacheRecovery, URL, URL) async throws -> Recording = {
            try await $0.recover($1, to: $2, removeSourceAfterCommit: false)
        }
    ) {
        self.fileURL = fileURL
        self.store = store
        self.writeMetadata = writeMetadata
        self.publish = publish

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public static func defaultURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harc/recovery.json")
    }

    public static func deterministicID(for sourceURL: URL, fileSize: Int, modifiedAt: Date?) -> String {
        let modified = modifiedAt.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        return "interruptedWAV:\(sourceURL.standardizedFileURL.path):\(fileSize):\(modified)"
    }

    public func scanCache(cacheDirectory: URL, destinationDirectory: URL) async throws {
        try loadIfNeeded()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var publicationSources: Set<String> = []
        for journal in files where journal.lastPathComponent.hasSuffix(".wav.publication.json") {
            let source = journal.deletingPathExtension().deletingPathExtension()
            guard let publication = try RecordingPublication.load(for: source) else { continue }
            publicationSources.insert(source.standardizedFileURL.path)
            if let index = artifactIndex(forSourceURL: source) {
                // Preserve existing terminal decisions and the original source
                // identity. Pending entries can resume through this same intent.
                if artifacts[index].status == .recovered,
                   try await store.fetchByWavPath(publication.destination.path) != nil {
                    try publication.finishLibraryCommit()
                }
                continue
            }
            if try await store.fetchByWavPath(publication.destination.path) != nil {
                try publication.finishLibraryCommit()
                continue
            }
            var artifact = RecoveryArtifact(
                id: "publication:\(publication.id.uuidString.lowercased())",
                kind: .destinationMoveFailed,
                sourceURL: source,
                destinationURL: publication.destination.deletingLastPathComponent(),
                title: "Finish recording publication",
                detail: "Resume the saved destination without creating another recording."
            )
            artifact.recoveryOutputURL = publication.destination
            var candidate = artifacts
            candidate.append(artifact)
            try persist(candidate)
        }

        for url in files where url.pathExtension.lowercased() == "wav" {
            guard !publicationSources.contains(url.standardizedFileURL.path) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let fileSize = values?.fileSize ?? 0
            guard fileSize > 0 else { continue }
            if try await store.fetchByWavPath(url.path) != nil { continue }

            let id = Self.deterministicID(
                for: url,
                fileSize: fileSize,
                modifiedAt: values?.contentModificationDate
            )
            guard artifactIndex(forSourceURL: url) == nil else { continue }

            var candidate = artifacts
            candidate.append(
                RecoveryArtifact(
                    id: id,
                    kind: .interruptedWAV,
                    sourceURL: url,
                    destinationURL: try CaptureDestinationBinding.load(for: url)?.baseDirectory ?? destinationDirectory,
                    title: "Interrupted recording",
                    detail: "\(fileSize) bytes in cache"
                )
            )
            // Commit before the next store await can admit another mutation.
            try persist(candidate)
        }
    }

    public func enqueue(_ artifact: RecoveryArtifact) async throws {
        try loadIfNeeded()
        try requireAvailable(artifact)
        if let existing = artifacts.first(where: { $0.id == artifact.id }) {
            try requireAvailable(existing)
            guard existing.sourceURL.standardizedFileURL == artifact.sourceURL.standardizedFileURL else {
                throw QueueError.sourceIdentityChanged(artifact.id)
            }
        }
        var candidate = artifacts
        if let index = candidate.firstIndex(where: {
            $0.sourceURL.standardizedFileURL == artifact.sourceURL.standardizedFileURL
        }) {
            var incoming = artifact
            incoming.id = candidate[index].id
            candidate[index] = merge(existing: candidate[index], incoming: incoming)
        } else {
            candidate.append(artifact)
        }
        try persist(candidate)
    }

    public func fetchAll() async throws -> [RecoveryArtifact] {
        try loadIfNeeded()
        // A persisted intent is not evidence that a worker is still alive.
        // Project interrupted intents as retryable without claiming a new
        // durable transition when metadata storage may itself be unavailable.
        return artifacts.map { artifact in
            var visible = artifact
            if visible.status == .recovering,
               !recoveringSources.contains(visible.sourceURL.standardizedFileURL.path) {
                visible.status = .failed
                visible.lastError = "Recovery was interrupted before completion was recorded. Retry to resume safely."
            }
            return visible
        }.sorted { lhs, rhs in
            if lhs.status == rhs.status {
                return lhs.createdAt > rhs.createdAt
            }
            return statusRank(lhs.status) < statusRank(rhs.status)
        }
    }

    @discardableResult
    public func recover(id: String) async throws -> RecoveryArtifact {
        try loadIfNeeded()
        guard let index = artifacts.firstIndex(where: { $0.id == id }) else {
            throw QueueError.artifactNotFound(id)
        }
        try requireAvailable(artifacts[index])
        if artifacts[index].status == .recovered {
            return artifacts[index]
        }
        guard let destination = artifacts[index].destinationURL else {
            throw QueueError.missingDestination(id)
        }

        let source = artifacts[index].sourceURL
        let sourceIdentity = source.standardizedFileURL.path
        recoveringSources.insert(sourceIdentity)
        defer { recoveringSources.remove(sourceIdentity) }
        let recovery = RecordingCacheRecovery(
            cacheDirectory: source.deletingLastPathComponent(),
            destinationDirectory: destination,
            store: store
        )
        let output = try artifacts[index].recoveryOutputURL
            ?? RecordingPublication.load(for: source)?.destination
            ?? recovery.plannedDestination(for: source)
        var starting = artifacts
        starting[index].status = .recovering
        starting[index].recoveryOutputURL = output
        starting[index].updatedAt = Date()
        starting[index].lastError = nil
        try persist(starting)

        var completed = starting[index]

        do {
            let recording = try await publish(recovery, source, output)
            completed.status = .recovered
            completed.destinationURL = URL(fileURLWithPath: recording.wavPath)
            completed.recordingID = recording.id
            completed.updatedAt = Date()
            completed.lastError = nil
        } catch {
            completed.status = .failed
            completed.updatedAt = Date()
            completed.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        var candidate = artifacts
        candidate[index] = completed
        try persist(candidate)
        if completed.status == .recovered,
           completed.destinationURL?.standardizedFileURL != source.standardizedFileURL {
            // Publication and queue completion both succeeded. A failed cleanup
            // leaves an already-accounted-for cache file, never a new recovery.
            do {
                if let publication = try RecordingPublication.load(for: source) {
                    try publication.finishLibraryCommit()
                } else {
                    if let destination = completed.destinationURL {
                        try CaptureDestinationBinding.load(for: source)?.validate(destination: destination)
                    }
                    try? FileManager.default.removeItem(at: source)
                    try? FileManager.default.removeItem(at: CaptureIntegrityReport.sidecarURL(for: source))
                    if !FileManager.default.fileExists(atPath: source.path) {
                        try? FileManager.default.removeItem(at: CaptureDestinationBinding.url(for: source))
                    }
                }
            } catch {
                // Keep both the source and journal if cleanup validation fails.
            }
        }
        return completed
    }

    @discardableResult
    public func discard(id: String) async throws -> RecoveryArtifact {
        try loadIfNeeded()
        guard let index = artifacts.firstIndex(where: { $0.id == id }) else {
            throw QueueError.artifactNotFound(id)
        }
        try requireAvailable(artifacts[index])
        var candidate = artifacts
        candidate[index].status = .discarded
        candidate[index].updatedAt = Date()
        candidate[index].lastError = nil
        try persist(candidate)
        return candidate[index]
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try decoder.decode([RecoveryArtifact].self, from: data)
            artifacts = decoded
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            artifacts = []
        }
        // A failed read or decode must remain retryable and must never permit
        // the original metadata to be overwritten by an empty in-memory queue.
        loaded = true
    }

    private func persist(_ candidate: [RecoveryArtifact]) throws {
        let parent = fileURL.deletingLastPathComponent()
        try DurableFileIO.createDirectory(at: parent)
        let data = try encoder.encode(candidate)
        try writeMetadata(data, fileURL)
        artifacts = candidate
    }

    private func requireAvailable(_ artifact: RecoveryArtifact) throws {
        guard !recoveringSources.contains(artifact.sourceURL.standardizedFileURL.path) else {
            throw QueueError.artifactBusy(artifact.id)
        }
    }

    private func merge(existing: RecoveryArtifact, incoming: RecoveryArtifact) -> RecoveryArtifact {
        var merged = incoming
        merged.createdAt = existing.createdAt
        merged.recoveryOutputURL = existing.recoveryOutputURL
        if existing.status == .recovered || existing.status == .discarded {
            merged.status = existing.status
            merged.recordingID = existing.recordingID
            merged.destinationURL = existing.destinationURL
            merged.lastError = existing.lastError
        }
        return merged
    }

    private func artifactIndex(forSourceURL sourceURL: URL) -> Int? {
        let path = sourceURL.standardizedFileURL.path
        return artifacts.firstIndex { artifact in
            artifact.sourceURL.standardizedFileURL.path == path
        }
    }

    private func statusRank(_ status: RecoveryArtifact.Status) -> Int {
        switch status {
        case .pending, .recovering, .failed:
            return 0
        case .recovered:
            return 1
        case .skipped:
            return 2
        case .discarded:
            return 3
        }
    }
}
